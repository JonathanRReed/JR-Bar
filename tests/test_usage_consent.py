"""Provider usage is off until the person turns that provider on.

A provider's quota read either asks that provider's servers for a number or
reads a sign-in another app keeps. Both are off on a fresh install, one
provider at a time, and these tests prove it with a tripwire on every way out
(HTTP, probes, the credential store, auth files, browser cookie files,
sqlite, subprocess): with default settings a full refresh of every provider
touches none of them. Everything is synthetic; nothing reaches a real
network, home folder or Keychain, and nothing sleeps.
"""

from __future__ import annotations

import contextlib
import io
import json
import sqlite3
import subprocess
import threading
import urllib.request
from collections.abc import Iterator
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest

import jrbar.core_runtime as core_runtime
from jrbar import provider_management as pm
from jrbar import provider_usage_cli, provider_usage_runtime
from jrbar.adaptive_refresh import degraded_signature
from jrbar.core_server import CommandError
from jrbar.provider_usage_codex_claude import (
    collect_claude_local_only,
    collect_codex_local_only,
)
from jrbar.provider_usage_collectors import (
    ProviderHttpError,
    collect_opencode_local_only,
)
from jrbar.provider_usage_consent import (
    ConsentGatedCollector,
    consent_gated_collectors,
    migrate_usage_consent,
    overlay_usage_off,
    reading_came_from_consented_source,
    usage_consent_row,
    usage_disclosure,
    usage_disclosures,
    usage_off_snapshot,
)
from jrbar.provider_usage_platform import (
    USAGE_OFF_REASON,
    USAGE_OFF_WORDS,
    ProviderSourceState,
    ProviderUsageSnapshot,
    UsageLane,
    provider_descriptors,
    provider_status_line,
)
from jrbar.provider_usage_runtime import ProviderUsageService, ProviderUsageState
from jrbar.provider_usage_settings import (
    USAGE_CONSENT_MIGRATION_VERSION,
    USAGE_CONSENT_VERSION,
    ProviderUsageSettingsError,
    default_provider_usage_settings,
    load_provider_usage_settings,
    save_provider_usage_settings,
)

NOW = 1_789_347_200.0
PROVIDERS = tuple(item.provider_id for item in provider_descriptors())

#: Files that hold a sign-in, by the name they are read under.
CREDENTIAL_FILES = {
    "auth.json": {"codex", "grok", "opencode"},
    "oauth_creds.json": {"gemini", "antigravity"},
    ".claude.json": {"claude"},
    "state.vscdb": {"cursor"},
    "cookies.sqlite": {"cursor", "devin"},
}

#: Which provider a host belongs to.
HOSTS = {
    "cursor.com": "cursor",
    "app.devin.ai": "devin",
    "cli-chat-proxy.grok.com": "grok",
    "cloudcode-pa.googleapis.com": "gemini",
    "oauth2.googleapis.com": "gemini",
    "api.openai.com": "openai-api",
    "opencode.ai": "opencode",
    "api.anthropic.com": "claude",
}


# --- the tripwire -------------------------------------------------------------------------------


class Tripwire:
    """Records every attempt to ask, probe, spawn or read a sign-in."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        #: (owners, kind, detail); owners are the providers it could belong to.
        self.events: list[tuple[frozenset[str], str, str]] = []

    def note(self, owners, kind: str, detail: str) -> None:
        with self._lock:
            self.events.append((frozenset(owners), kind, detail))

    def kinds(self) -> list[str]:
        return [f"{kind}:{detail}" for _owners, kind, detail in self.events]

    def owners(self) -> set[str]:
        found: set[str] = set()
        for owners, _kind, _detail in self.events:
            found |= owners
        return found

    # -- the seams ---

    def http_json(self, method, url, **_kwargs):
        host = url.split("/")[2]
        self.note({HOSTS.get(host, "?")}, "http", f"{method} {host}")
        raise ProviderHttpError(0, "network_error")

    def live_probe(self):
        self.note({"codex"}, "probe", "codex app-server")
        return None


class FakeCredentialStore:
    def __init__(self, tripwire: Tripwire) -> None:
        self._tripwire = tripwire

    def get(self, provider_id, account):
        self._tripwire.note({provider_id}, "credential", f"{provider_id}/{account}")
        return SimpleNamespace(available=False, secret=None, reason="credential_not_found")

    def get_for_instance(self, key, account):
        return self.get(key.value[0], account)

    def set(self, provider_id, account, secret):
        self._tripwire.note({provider_id}, "credential-write", f"{provider_id}/{account}")

    def set_for_instance(self, key, account, secret):
        self.set(key.value[0], account, secret)

    def delete(self, provider_id, account):
        self._tripwire.note({provider_id}, "credential-delete", f"{provider_id}/{account}")
        return False


def _credential_owners(path: object) -> set[str] | None:
    name = Path(str(path)).name
    return CREDENTIAL_FILES.get(name) or CREDENTIAL_FILES.get(name.lower())


@contextlib.contextmanager
def armed(monkeypatch: pytest.MonkeyPatch) -> Iterator[Tripwire]:
    """Put a recorder on every way a collector could ask or read a sign-in."""
    wire = Tripwire()
    real_open = open

    def recording_open(file, *args, **kwargs):
        owners = _credential_owners(file) if isinstance(file, (str, Path)) else None
        if owners:
            wire.note(owners, "file", Path(str(file)).name)
        return real_open(file, *args, **kwargs)

    real_connect = sqlite3.connect

    def recording_connect(database, *args, **kwargs):
        owners = _credential_owners(str(database).split("?")[0].replace("file:", ""))
        if owners:
            wire.note(owners, "sqlite", Path(str(database).split("?")[0]).name)
        return real_connect(database, *args, **kwargs)

    def recording_run(args, *a, **kw):
        argv = [str(part) for part in args] if not isinstance(args, str) else [args]
        program = Path(argv[0]).name
        owners = {"antigravity"} if program in {"ps", "lsof"} else {"claude", "devin", "grok"}
        wire.note(owners, "subprocess", program)
        return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

    def recording_popen(args, *a, **kw):
        argv = [str(part) for part in args] if not isinstance(args, str) else [args]
        wire.note({"codex"}, "subprocess", Path(argv[0]).name)
        raise OSError("no such program in this test")

    def refusing_network(name):
        def refuse(*_args, **_kwargs):
            wire.note({"?"}, "network", name)
            raise OSError(f"{name} refused in this test")

        return refuse

    def recording_fingerprint(home, provider_id, *, fresh=False):
        wire.note({provider_id}, "fingerprint", provider_id)
        return None

    monkeypatch.setattr("builtins.open", recording_open)
    monkeypatch.setattr("io.open", recording_open)
    monkeypatch.setattr(sqlite3, "connect", recording_connect)
    monkeypatch.setattr(subprocess, "run", recording_run)
    monkeypatch.setattr(subprocess, "Popen", recording_popen)
    monkeypatch.setattr(subprocess, "check_output", recording_run)
    monkeypatch.setattr(urllib.request, "urlopen", refusing_network("urlopen"))
    monkeypatch.setattr(urllib.request.OpenerDirector, "open", refusing_network("OpenerDirector.open"))
    monkeypatch.setattr("socket.create_connection", refusing_network("socket.create_connection"))
    monkeypatch.setattr(provider_usage_runtime, "credential_fingerprint", recording_fingerprint)
    yield wire


def _write_credential_files(home: Path) -> None:
    """Synthetic sign-ins in every place a collector looks."""
    files = {
        ".codex/auth.json": {"tokens": {"access_token": "synthetic-codex", "account_id": "acct-synthetic"}},
        ".grok/auth.json": {
            "https://auth.x.ai::synthetic": {
                "key": "synthetic-grok",
                "expires_at": NOW + 10_000,
                "email": "person@example.invalid",
            }
        },
        ".gemini/oauth_creds.json": {
            "access_token": "synthetic-gemini",
            "refresh_token": "synthetic-refresh",
            "expiry_date": (NOW + 10_000) * 1000,
            "email": "person@example.invalid",
        },
        ".claude.json": {"oauthAccount": {"emailAddress": "person@example.invalid"}},
        ".local/share/opencode/auth.json": {"opencode-go": {"type": "api", "key": "synthetic-go"}},
    }
    for relative, document in files.items():
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(document), encoding="utf-8")
    for relative in (
        "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
        "Library/Application Support/Firefox/Profiles/synthetic.default/cookies.sqlite",
    ):
        path = home / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"")


@pytest.fixture
def home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / ".local" / "share"))
    monkeypatch.delenv("OPENCODE_API_KEY", raising=False)
    _write_credential_files(tmp_path)
    return tmp_path


def _service(
    home: Path,
    wire: Tripwire,
    settings,
    *,
    incident_lookup=None,
    state_loader=None,
) -> ProviderUsageService:
    kwargs = {}
    if incident_lookup is not None:
        kwargs["incident_lookup"] = incident_lookup
    if state_loader is not None:
        kwargs["state_loader"] = state_loader
    return ProviderUsageService(
        settings_loader=lambda: settings,
        credentials=FakeCredentialStore(wire),
        home=home,
        collectors=consent_gated_collectors(
            live_probe=wire.live_probe,
            http_json=wire.http_json,
        ),
        clock=lambda: NOW,
        **kwargs,
    )


def _consented(settings, *provider_ids: str, source: str = "settings"):
    for provider_id in provider_ids:
        settings = settings.with_usage_consent(provider_id, True, source=source, at=NOW)
    return settings


# --- fresh state is off -------------------------------------------------------------------------


def test_a_fresh_install_has_no_usage_consent_for_any_provider(tmp_path: Path) -> None:
    fresh = default_provider_usage_settings()
    assert [item.usage_consented for item in fresh.providers] == [False] * len(PROVIDERS)
    assert {item.usage_consent_version for item in fresh.providers} == {0}

    loaded = load_provider_usage_settings(tmp_path / "missing.json")
    assert not any(item.usage_consented for item in loaded.settings.providers)


def test_a_saved_document_from_before_consent_existed_loads_as_off(tmp_path: Path) -> None:
    path = tmp_path / "provider-usage.json"
    path.write_text(
        json.dumps(
            {
                "settings_schema_version": 3,
                "providers": [
                    {"provider_id": "claude", "enabled": True, "browser_sources": False},
                    {"provider_id": "opencode", "enabled": True, "browser_sources": False},
                ],
            }
        ),
        encoding="utf-8",
    )
    settings = load_provider_usage_settings(path).settings
    assert settings.usage_consent_migration == 0
    assert settings.preference("claude").enabled is True
    assert not any(item.usage_consented for item in settings.providers)


@pytest.mark.parametrize("bad", [True, -1, 1.5, "1", None, [1]])
def test_a_malformed_consent_in_a_document_is_off(tmp_path: Path, bad: object) -> None:
    path = tmp_path / "provider-usage.json"
    path.write_text(
        json.dumps(
            {
                "settings_schema_version": 3,
                "providers": [
                    {
                        "provider_id": "claude",
                        "enabled": True,
                        "browser_sources": False,
                        "usage_consent_version": bad,
                        "usage_consent_source": "settings",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    assert not load_provider_usage_settings(path).settings.preference("claude").usage_consented


def test_consent_round_trips_and_keeps_its_record(tmp_path: Path) -> None:
    path = tmp_path / "provider-usage.json"
    settings = default_provider_usage_settings().with_usage_consent("cursor", True, source="setup", at=NOW)
    save_provider_usage_settings(settings, path)
    document = json.loads(path.read_text(encoding="utf-8"))
    row = next(item for item in document["providers"] if item["provider_id"] == "cursor")
    assert row["usage_consent_version"] == USAGE_CONSENT_VERSION
    assert row["usage_consent_source"] == "setup"
    assert row["usage_consented_at"] == NOW
    again = load_provider_usage_settings(path).settings
    assert again.preference("cursor").usage_consented
    assert again.preference("cursor").usage_consent_source == "setup"
    assert not again.preference("claude").usage_consented


def test_withdrawing_consent_clears_the_whole_record() -> None:
    on = default_provider_usage_settings().with_usage_consent("grok", True, source="cli", at=NOW)
    off = on.with_usage_consent("grok", False, source="cli")
    row = off.preference("grok")
    assert (row.usage_consent_version, row.usage_consent_source, row.usage_consented_at) == (0, None, None)
    assert row.enabled is True, "turning usage off leaves the provider's local figures on"


def test_turning_usage_on_turns_the_provider_on_too() -> None:
    settings = default_provider_usage_settings()
    assert settings.preference("openai-api").enabled is False
    on = settings.with_usage_consent("openai-api", True, source="settings", at=NOW)
    assert on.preference("openai-api").enabled is True


def test_a_second_account_never_inherits_the_first_ones_consent() -> None:
    from jrbar.provider_instances import ProviderInstanceKey, ProviderInstanceProfile

    on = default_provider_usage_settings().with_usage_consent("claude", True, source="setup", at=NOW)
    added = on.with_profile(ProviderInstanceProfile(ProviderInstanceKey("claude", "work"), label="Work"))
    assert added.preference("claude").usage_consented
    assert not added.preference("claude", "work").usage_consented


def test_an_unknown_consent_source_or_value_is_refused() -> None:
    settings = default_provider_usage_settings()
    with pytest.raises(ProviderUsageSettingsError):
        settings.with_usage_consent("claude", True, source="somewhere-else")
    with pytest.raises(ProviderUsageSettingsError):
        settings.with_usage_consent("claude", "yes", source="settings")  # type: ignore[arg-type]


def test_a_newer_consent_version_asks_again(monkeypatch: pytest.MonkeyPatch) -> None:
    import jrbar.provider_usage_settings as settings_module

    on = default_provider_usage_settings().with_usage_consent("claude", True, source="settings", at=NOW)
    assert on.preference("claude").usage_consented
    monkeypatch.setattr(settings_module, "USAGE_CONSENT_VERSION", USAGE_CONSENT_VERSION + 1)
    assert not on.preference("claude").usage_consented


# --- the proof: a full refresh with default settings asks and reads nothing ---------------------


def test_a_full_refresh_on_fresh_settings_asks_and_reads_nothing(home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    with armed(monkeypatch) as wire:
        service = _service(home, wire, default_provider_usage_settings())
        state = service.refresh_now(force=True)
        service.close()

    assert wire.kinds() == [], "nothing was asked, probed, spawned or read"
    by_provider = {item.provider_id: item for item in state.snapshots}
    assert set(by_provider) == set(PROVIDERS)
    for provider_id in PROVIDERS:
        snapshot = by_provider[provider_id]
        if not default_provider_usage_settings().preference(provider_id).enabled:
            assert snapshot.state is ProviderSourceState.DISABLED
            continue
        assert snapshot.state is ProviderSourceState.NEEDS_CONSENT, provider_id
        assert snapshot.reason_code == USAGE_OFF_REASON, provider_id
        assert snapshot.action_label == f"Turn on {usage_disclosure(provider_id).label} usage"
        assert snapshot.lanes == (), f"{provider_id} invented a lane"


@pytest.mark.parametrize("provider_id", PROVIDERS)
def test_each_consent_turns_on_exactly_its_own_provider(
    home: Path, monkeypatch: pytest.MonkeyPatch, provider_id: str
) -> None:
    with armed(monkeypatch) as wire:
        service = _service(home, wire, _consented(default_provider_usage_settings(), provider_id))
        state = service.refresh_now(force=True)
        service.close()

    assert wire.events, f"{provider_id} did not try anything once it was turned on"
    for owners, kind, detail in wire.events:
        assert provider_id in owners, f"{kind} {detail} belongs to {sorted(owners)}, not {provider_id}"
    others = [item for item in state.snapshots if item.provider_id != provider_id]
    for snapshot in others:
        if not default_provider_usage_settings().preference(snapshot.provider_id).enabled:
            assert snapshot.state is ProviderSourceState.DISABLED
            continue
        assert snapshot.reason_code == USAGE_OFF_REASON, snapshot.provider_id
    own = next(item for item in state.snapshots if item.provider_id == provider_id)
    assert own.reason_code != USAGE_OFF_REASON


def test_two_providers_on_ask_only_for_those_two(home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    with armed(monkeypatch) as wire:
        service = _service(home, wire, _consented(default_provider_usage_settings(), "grok", "cursor"))
        service.refresh_now(force=True)
        service.close()
    allowed = {"grok", "cursor"}
    assert wire.events
    assert all(owners & allowed for owners, _kind, _detail in wire.events), wire.kinds()
    assert wire.owners() >= allowed


def test_the_credential_sources_of_a_provider_that_is_off_are_not_even_checked(
    home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    with armed(monkeypatch) as wire:
        service = _service(home, wire, _consented(default_provider_usage_settings(), "codex"))
        service.refresh_now(force=True)
        service.close()
    fingerprints = [detail for _o, kind, detail in wire.events if kind == "fingerprint"]
    assert fingerprints == ["codex"], "only the provider that is on has its sign-in looked at"


def test_the_default_collectors_are_all_behind_consent() -> None:
    collectors = provider_usage_runtime._default_collectors()
    assert set(collectors) == set(PROVIDERS)
    assert all(isinstance(item, ConsentGatedCollector) for item in collectors.values())
    assert all(item.requires_usage_consent for item in collectors.values())


def test_a_collector_handed_off_settings_never_reaches_its_granted_path() -> None:
    reached: list[str] = []

    def granted(*_args):
        reached.append("granted")
        raise AssertionError("the request ran without consent")

    collector = ConsentGatedCollector("cursor", granted)
    off = collector(SimpleNamespace(usage_consent_version=0, source_instance_id="default"), Path("."), NOW, None)
    assert reached == []
    assert off.state is ProviderSourceState.NEEDS_CONSENT and off.reason_code == USAGE_OFF_REASON
    on = SimpleNamespace(usage_consent_version=USAGE_CONSENT_VERSION, source_instance_id="default")
    with pytest.raises(AssertionError):
        collector(on, Path("."), NOW, None)
    assert reached == ["granted"]


# --- local reads stay on ------------------------------------------------------------------------


def test_codex_with_usage_off_keeps_the_numbers_its_own_rollouts_recorded(tmp_path: Path) -> None:
    def scanner(_home, _observed):
        return {
            "input_tokens": 1200,
            "cached_input_tokens": 200,
            "output_tokens": 300,
            "model_count": 2,
            "windows_observed_at": NOW - 60,
            "windows": [{"label": "primary", "used_percent": 40.0, "resets_at": NOW + 3600, "window_minutes": 300}],
        }

    snapshot = collect_codex_local_only(
        default_provider_usage_settings().preference("codex"),
        home=tmp_path,
        observed_at=NOW,
        local_scanner=scanner,
    )
    assert snapshot.lanes and {lane.source_id for lane in snapshot.lanes} == {"codex-rollouts"}
    assert snapshot.input_tokens == 1200


def test_codex_with_usage_off_and_no_rollouts_says_usage_off(tmp_path: Path) -> None:
    snapshot = collect_codex_local_only(
        default_provider_usage_settings().preference("codex"),
        home=tmp_path,
        observed_at=NOW,
        local_scanner=lambda _home, _observed: None,
    )
    assert snapshot.reason_code == USAGE_OFF_REASON and snapshot.lanes == ()


def test_claude_with_usage_off_keeps_tokens_and_the_status_line(tmp_path: Path) -> None:
    local = {"input_tokens": 50, "cached_input_tokens": 10, "output_tokens": 20, "model_count": 1}
    snapshot = collect_claude_local_only(
        default_provider_usage_settings().preference("claude"),
        home=tmp_path,
        observed_at=NOW,
        local_scanner=lambda _home, _observed: local,
        statusline_reader=lambda _observed: None,
    )
    assert snapshot.reason_code == USAGE_OFF_REASON
    assert snapshot.lanes == ()
    assert (snapshot.input_tokens, snapshot.output_tokens) == (50, 20)


def test_claude_with_usage_off_shows_the_status_line_reading_the_person_installed(
    tmp_path: Path,
) -> None:
    from jrbar.claude_statusline_source import StatusLineReading, StatusLineWindow

    reading = StatusLineReading(
        None,
        None,
        (("five_hour", StatusLineWindow(25.0, NOW + 3600)),),
        NOW - 5,
    )
    snapshot = collect_claude_local_only(
        default_provider_usage_settings().preference("claude"),
        home=tmp_path,
        observed_at=NOW,
        local_scanner=lambda _home, _observed: None,
        statusline_reader=lambda _observed: reading,
    )
    assert snapshot.state is ProviderSourceState.READY
    assert {lane.source_id for lane in snapshot.lanes} == {"claude-statusline"}


def test_opencode_with_usage_off_counts_tokens_and_reads_no_key(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root = tmp_path / "opencode"
    root.mkdir()
    with sqlite3.connect(root / "opencode.db") as connection:
        connection.execute("CREATE TABLE session (tokens_input INTEGER, tokens_output INTEGER, model TEXT)")
        connection.execute("INSERT INTO session VALUES (700, 300, 'm')")
        connection.execute("CREATE TABLE message (time_created INTEGER, data TEXT)")
    (root / "auth.json").write_text(
        json.dumps({"opencode-go": {"type": "api", "key": "synthetic-go"}}), encoding="utf-8"
    )
    monkeypatch.setenv("OPENCODE_API_KEY", "synthetic-env-key")
    with armed(monkeypatch) as wire:
        snapshot = collect_opencode_local_only(
            default_provider_usage_settings().preference("opencode"),
            observed_at=NOW,
            env={"XDG_DATA_HOME": str(tmp_path), "OPENCODE_API_KEY": "synthetic-env-key"},
        )
    assert [kind for kind in wire.kinds() if kind.startswith("file:")] == [], "auth.json was not read"
    assert snapshot.reason_code == USAGE_OFF_REASON
    assert (snapshot.input_tokens, snapshot.output_tokens) == (700, 300)


# --- an honest state, never an invented lane ----------------------------------------------------


def test_the_off_state_is_an_actionable_needs_consent_with_no_lane() -> None:
    snapshot = usage_off_snapshot("claude", observed_at=NOW)
    assert snapshot.state is ProviderSourceState.NEEDS_CONSENT
    assert snapshot.lanes == ()
    assert snapshot.action_label == "Turn on Claude usage"
    assert provider_status_line(snapshot) == f"Claude · {USAGE_OFF_WORDS}"
    assert USAGE_OFF_WORDS == "off (not turned on)"


def test_a_provider_whose_usage_is_off_is_not_degraded_and_not_retried(
    home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lookups: list[str] = []
    with armed(monkeypatch) as wire:
        service = _service(
            home,
            wire,
            default_provider_usage_settings(),
            incident_lookup=lambda provider_id, _at: lookups.append(provider_id),
        )
        state = service.refresh_now(force=True)
        plan = service.cadence_plan()
        service.close()
    assert degraded_signature(state.snapshots) == frozenset()
    assert plan.reason.value != "degraded_source"
    assert lookups == [], "no status page is looked up for a provider that is off"


def test_turning_usage_off_drops_the_reading_it_allowed(home: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    lane = UsageLane(
        provider_id="cursor",
        lane_id="plan",
        label="Plan",
        remaining_percent=60.0,
        reset_at=NOW + 600,
        scope="all",
        model=None,
        feature=None,
        bindable=True,
        source_id="cursor-account-api",
    )

    def granted(_preference, _home, observed, _credentials):
        return replace(
            usage_off_snapshot("cursor", observed_at=observed),
            state=ProviderSourceState.READY,
            reason_code=None,
            action_label=None,
            lanes=(lane,),
        )

    settings = {"value": _consented(default_provider_usage_settings(), "cursor")}
    service = ProviderUsageService(
        settings_loader=lambda: settings["value"],
        credentials=object(),
        home=home,
        collectors={"cursor": ConsentGatedCollector("cursor", granted)},
        clock=lambda: NOW,
    )
    on = service.refresh_now(force=True).by_provider("cursor")
    assert on.state is ProviderSourceState.READY and on.lanes

    settings["value"] = settings["value"].with_usage_consent("cursor", False, source="settings")
    service.note_settings_updated(settings["value"])
    off = service.refresh_now(force=True).by_provider("cursor")
    service.close()
    assert off.reason_code == USAGE_OFF_REASON
    assert off.lanes == (), "the old number is not kept as a stale reading"


def test_a_saved_reading_does_not_outlive_the_consent_that_allowed_it(
    home: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    lane = UsageLane("grok", "credits", "Credits", 30.0, NOW + 600, "all", None, None, True, "grok-billing")
    saved = replace(
        usage_off_snapshot("grok", observed_at=NOW - 30),
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=(lane,),
    )
    with armed(monkeypatch) as wire:
        service = _service(
            home,
            wire,
            default_provider_usage_settings(),
            state_loader=lambda: ProviderUsageState((saved,), NOW - 30, None, False),
        )
        shown = service.snapshot().by_provider("grok")
        service.close()
    assert shown.reason_code == USAGE_OFF_REASON and shown.lanes == ()
    assert wire.kinds() == []


def test_overlay_keeps_local_readings_and_replaces_gated_ones() -> None:
    off = default_provider_usage_settings().preference("codex")
    local = replace(
        usage_off_snapshot("codex", observed_at=NOW),
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
        lanes=(UsageLane("codex", "weekly", "Weekly", 50.0, NOW + 60, "all", None, None, True, "codex-rollouts"),),
        input_tokens=7,
    )
    assert overlay_usage_off(local, off) is local
    live = replace(
        local,
        lanes=(UsageLane("codex", "weekly", "Weekly", 50.0, NOW + 60, "all", None, None, True, "codex-app-server"),),
    )
    replaced = overlay_usage_off(live, off)
    assert replaced.reason_code == USAGE_OFF_REASON and replaced.lanes == ()
    assert replaced.input_tokens == 7, "token totals counted on this Mac stay"


# --- the migration: keep what works, and only that ----------------------------------------------


def _reading(provider_id: str, source_id: str, *, state=ProviderSourceState.READY) -> ProviderUsageSnapshot:
    lane = UsageLane(provider_id, "weekly", "Weekly", 40.0, NOW + 600, "all", None, None, True, source_id)
    return replace(
        usage_off_snapshot(provider_id, observed_at=NOW - 100),
        state=state,
        reason_code=None if state is ProviderSourceState.READY else "network_unavailable",
        action_label=None if state is ProviderSourceState.READY else "Retry",
        lanes=(lane,),
    )


def _old_state() -> ProviderUsageState:
    failing = replace(
        usage_off_snapshot("devin", observed_at=NOW - 100),
        state=ProviderSourceState.NEEDS_SIGN_IN,
        reason_code="authentication_required",
        action_label="Reconnect Devin",
    )
    no_quota = replace(
        usage_off_snapshot("opencode", observed_at=NOW - 100, input_tokens=5),
        state=ProviderSourceState.UNSUPPORTED,
        reason_code="opencode_no_quota_source",
        action_label=None,
    )
    tokens_only = replace(
        usage_off_snapshot("gemini", observed_at=NOW - 100),
        state=ProviderSourceState.READY,
        reason_code=None,
        action_label=None,
    )
    return ProviderUsageState(
        (
            _reading("claude", "claude-oauth"),
            _reading("codex", "codex-rollouts"),
            _reading("cursor", "cursor-account-api"),
            _reading("grok", "grok-billing", state=ProviderSourceState.STALE),
            failing,
            no_quota,
            tokens_only,
            replace(_reading("openai-api", "openai-api"), lanes=()),
        ),
        NOW - 100,
        None,
        False,
    )


def _existing_install(tmp_path: Path):
    """An install from before consent: settings saved, a state file written."""
    path = tmp_path / "provider-usage.json"
    settings = default_provider_usage_settings().with_enabled("gemini", False)
    save_provider_usage_settings(settings, path)
    return path


def test_the_migration_keeps_only_providers_that_were_on_and_working(tmp_path: Path) -> None:
    path = _existing_install(tmp_path)
    logs: list[str] = []
    report = migrate_usage_consent(path, _old_state, log=logs.append)

    assert report.ran
    assert set(report.migrated) == {("claude", "default"), ("cursor", "default"), ("grok", "default")}
    settings = load_provider_usage_settings(path).settings
    for provider_id in PROVIDERS:
        expected = provider_id in {"claude", "cursor", "grok"}
        assert settings.preference(provider_id).usage_consented is expected, provider_id
    kept = settings.preference("claude")
    assert kept.usage_consent_source == "migration"
    assert kept.usage_consent_version == USAGE_CONSENT_VERSION
    assert kept.usage_consented_at is None
    assert settings.usage_consent_migration == USAGE_CONSENT_MIGRATION_VERSION
    assert len(logs) == 3
    assert all(line.startswith("usage consent: kept ") for line in logs)
    assert not any("codex" in line for line in logs), "local rollouts alone are not a reason"


def test_a_disabled_provider_that_once_worked_stays_off(tmp_path: Path) -> None:
    path = tmp_path / "provider-usage.json"
    save_provider_usage_settings(default_provider_usage_settings().with_enabled("cursor", False), path)
    migrate_usage_consent(path, _old_state)
    assert not load_provider_usage_settings(path).settings.preference("cursor").usage_consented


def test_opencode_go_migrates_only_if_it_already_returned_data(tmp_path: Path) -> None:
    path = _existing_install(tmp_path)
    migrate_usage_consent(path, _old_state)
    assert not load_provider_usage_settings(path).settings.preference("opencode").usage_consented

    other = tmp_path / "second.json"
    save_provider_usage_settings(default_provider_usage_settings(), other)
    returned = ProviderUsageState((_reading("opencode", "opencode-go-api"),), NOW, None, False)
    migrate_usage_consent(other, lambda: returned)
    assert load_provider_usage_settings(other).settings.preference("opencode").usage_consented


def test_the_migration_runs_once_and_is_idempotent(tmp_path: Path) -> None:
    path = _existing_install(tmp_path)
    logs: list[str] = []
    migrate_usage_consent(path, _old_state, log=logs.append)
    first = path.read_text(encoding="utf-8")

    again = migrate_usage_consent(path, _old_state, log=logs.append)
    assert not again.ran and again.reason == "already_ran"
    assert path.read_text(encoding="utf-8") == first
    assert len(logs) == 3

    # A reading that appears later cannot migrate anything.
    later = ProviderUsageState((_reading("devin", "devin-account-api"),), NOW, None, False)
    migrate_usage_consent(path, lambda: later, log=logs.append)
    assert not load_provider_usage_settings(path).settings.preference("devin").usage_consented


def test_a_fresh_mac_writes_nothing_and_turns_nothing_on(tmp_path: Path) -> None:
    path = tmp_path / "provider-usage.json"
    report = migrate_usage_consent(path, lambda: ProviderUsageState((), None, None, False))
    assert not report.ran and report.reason == "fresh"
    assert not path.exists()
    assert not any(item.usage_consented for item in load_provider_usage_settings(path).settings.providers)


def test_an_install_with_nothing_working_is_marked_done_and_stays_off(tmp_path: Path) -> None:
    path = _existing_install(tmp_path)
    report = migrate_usage_consent(path, lambda: ProviderUsageState((), None, None, False))
    assert report.ran and report.migrated == ()
    settings = load_provider_usage_settings(path).settings
    assert settings.usage_consent_migration == USAGE_CONSENT_MIGRATION_VERSION
    assert not any(item.usage_consented for item in settings.providers)


def test_a_person_who_turned_a_provider_off_is_not_turned_back_on_by_an_old_reading(
    tmp_path: Path,
) -> None:
    path = tmp_path / "provider-usage.json"
    managed = (
        default_provider_usage_settings()
        .with_usage_consent("claude", True, source="setup", at=NOW)
        .with_usage_consent("claude", False, source="settings")
    )
    save_provider_usage_settings(managed, path)
    migrate_usage_consent(path, _old_state)
    assert not load_provider_usage_settings(path).settings.preference("claude").usage_consented


def test_a_read_only_settings_document_is_left_alone(tmp_path: Path) -> None:
    path = tmp_path / "provider-usage.json"
    path.write_text(json.dumps({"settings_schema_version": 99}), encoding="utf-8")
    before = path.read_text(encoding="utf-8")
    report = migrate_usage_consent(path, _old_state)
    assert not report.ran and report.reason == "settings_read_only"
    assert path.read_text(encoding="utf-8") == before


def test_which_readings_count_as_working() -> None:
    assert reading_came_from_consented_source(_reading("claude", "claude-oauth"))
    assert not reading_came_from_consented_source(_reading("claude", "claude-statusline"))
    assert not reading_came_from_consented_source(_reading("codex", "codex-rollouts"))
    assert reading_came_from_consented_source(_reading("codex", "codex-app-server"))
    assert not reading_came_from_consented_source(
        _reading("cursor", "cursor-account-api", state=ProviderSourceState.ERROR)
    )


# --- the commands and the CLI -------------------------------------------------------------------


def test_the_provider_rows_carry_the_switch_and_its_words(home: Path) -> None:
    rows = pm.provider_rows(credentials=FakeCredentialStore(Tripwire()), home=home)
    assert {row["id"] for row in rows} == set(PROVIDERS)
    for row in rows:
        consent = row["usage_consent"]
        assert consent["granted"] is False
        assert consent["required_version"] == USAGE_CONSENT_VERSION
        assert consent["question"] == f"Show {row['label']} usage?"
        assert consent["summary"] and consent["detail"]


def test_set_provider_usage_consent_flips_exactly_one_provider(home: Path) -> None:
    store = FakeCredentialStore(Tripwire())
    row = pm.set_provider_usage_consent("cursor", True, source="setup", credentials=store, home=home, clock=lambda: NOW)
    assert row["usage_consent"]["granted"] is True
    assert row["usage_consent"]["source"] == "setup"
    assert row["usage_consent"]["at"] == NOW
    rows = {item["id"]: item for item in pm.provider_rows(credentials=store, home=home)}
    assert [pid for pid, item in rows.items() if item["usage_consent"]["granted"]] == ["cursor"]

    off = pm.set_provider_usage_consent("cursor", False, credentials=store, home=home)
    assert off["usage_consent"]["granted"] is False and off["usage_consent"]["at"] is None


def test_set_provider_usage_consent_refuses_what_it_should(home: Path) -> None:
    store = FakeCredentialStore(Tripwire())
    with pytest.raises(pm.ProviderManagementError) as unknown:
        pm.set_provider_usage_consent("nope", True, credentials=store)
    assert unknown.value.code == "unknown_provider"
    with pytest.raises(pm.ProviderManagementError) as instance:
        pm.set_provider_usage_consent("claude", True, source_instance_id="work", credentials=store)
    assert instance.value.code == "unknown_instance"
    with pytest.raises(pm.ProviderManagementError) as source:
        pm.set_provider_usage_consent("claude", True, source="a-rule", credentials=store)
    assert source.value.code == "invalid_args"
    with pytest.raises(pm.ProviderManagementError) as flag:
        pm.set_provider_usage_consent("claude", "yes", credentials=store)  # type: ignore[arg-type]
    assert flag.value.code == "invalid_args"
    assert not any(item.usage_consented for item in load_provider_usage_settings().settings.providers)


class _Controller:
    def __init__(self, snapshots=()):
        self.refresh: list[dict] = []
        self.provider_usage_state = ProviderUsageState(tuple(snapshots), NOW, None, False)
        self._jrbar_provider_credential_store = FakeCredentialStore(Tripwire())

    def _request_provider_usage(self, **kwargs):
        self.refresh.append(kwargs)


def test_the_socket_command_turns_one_provider_on_and_asks_for_a_read(home: Path) -> None:
    controller = _Controller()
    reply = core_runtime._cmd_set_provider_usage_consent(
        controller, {"provider": "devin", "enabled": True, "source": "usage_center"}
    )
    assert reply["provider"]["usage_consent"]["granted"] is True
    assert reply["provider"]["usage_consent"]["source"] == "usage_center"
    assert controller.refresh == [{"force": True, "providers": ("devin",)}]
    saved = load_provider_usage_settings().settings
    assert [item.provider_id for item in saved.providers if item.usage_consented] == ["devin"]


@pytest.mark.parametrize(
    "args, code",
    [
        ({"enabled": True}, "invalid_args"),
        ({"provider": "devin"}, "invalid_args"),
        ({"provider": "devin", "enabled": "on"}, "invalid_args"),
        ({"provider": "devin", "enabled": True, "source": 5}, "invalid_args"),
        ({"provider": "nope", "enabled": True}, "unknown_provider"),
        ({"provider": "devin", "enabled": True, "source": "a-rule"}, "invalid_args"),
    ],
)
def test_the_socket_command_refuses_bad_arguments(home: Path, args: dict, code: str) -> None:
    with pytest.raises(CommandError) as error:
        core_runtime._cmd_set_provider_usage_consent(_Controller(), args)
    assert error.value.code == code


def test_a_sign_in_click_on_a_provider_that_is_off_is_refused_before_it_reads_anything(
    home: Path,
) -> None:
    controller = _Controller(snapshots=(usage_off_snapshot("claude", observed_at=NOW),))
    for command, args in (
        (core_runtime._cmd_provider_sign_in, {"provider": "claude"}),
        (core_runtime._cmd_provider_action, {"provider": "claude", "action": "resign_in"}),
        (core_runtime._cmd_provider_action, {"provider": "claude"}),
    ):
        with pytest.raises(CommandError) as error:
            command(controller, args)
        assert error.value.code == "usage_off"
        assert "Settings > Providers" in str(error.value)
    assert controller.refresh == []


def test_the_cli_reports_off_honestly_on_a_fresh_mac(tmp_path: Path) -> None:
    output = io.StringIO()
    assert provider_usage_cli.main(["status"], stdout=output, home=tmp_path) == 0
    text = output.getvalue()
    for label in ("Codex", "Claude", "Cursor", "Devin", "Grok", "Gemini", "Antigravity", "OpenCode"):
        assert f"{label} · off (not turned on)" in text, label
    assert "Action: Turn on Claude usage" in text
    assert "OpenAI API · off\n" in text, "a provider that is switched off says plain off"

    as_json = io.StringIO()
    assert provider_usage_cli.main(["status", "--json"], stdout=as_json, home=tmp_path) == 0
    rows = {row["provider_id"]: row for row in json.loads(as_json.getvalue())["providers"]}
    assert rows["claude"]["state"] == "needs_consent"
    assert rows["claude"]["reason"] == USAGE_OFF_REASON


def test_the_cli_status_does_not_show_an_old_reading_for_a_provider_that_is_off(tmp_path: Path) -> None:
    # The upgrade migration has already run, and the person never turned Cursor on.
    settings_path = tmp_path / "provider-usage.json"
    save_provider_usage_settings(
        default_provider_usage_settings().with_usage_consent_migration(USAGE_CONSENT_MIGRATION_VERSION),
        settings_path,
    )
    state = ProviderUsageState((_reading("cursor", "cursor-account-api"),), NOW, None, False)
    output = io.StringIO()
    provider_usage_cli.main(
        ["status"], stdout=output, home=tmp_path, settings_path=settings_path, state_loader=lambda: state
    )
    assert "Cursor · off (not turned on)" in output.getvalue()
    assert "Weekly" not in output.getvalue()


def test_the_cli_turns_one_provider_on_and_back_off_in_plain_words(tmp_path: Path) -> None:
    settings_path = tmp_path / "provider-usage.json"
    output = io.StringIO()
    assert (
        provider_usage_cli.main(
            ["usage", "claude", "on"],
            stdout=output,
            home=tmp_path,
            settings_path=settings_path,
            clock=lambda: NOW,
        )
        == 0
    )
    words = output.getvalue()
    assert "Claude usage on." in words and "api.anthropic.com" in words and "Nothing else is sent." in words
    settings = load_provider_usage_settings(settings_path).settings
    assert settings.preference("claude").usage_consent_source == "cli"
    assert [item.provider_id for item in settings.providers if item.usage_consented] == ["claude"]

    output = io.StringIO()
    assert (
        provider_usage_cli.main(["usage", "claude", "off"], stdout=output, home=tmp_path, settings_path=settings_path)
        == 0
    )
    assert "usage off" in output.getvalue()
    assert not load_provider_usage_settings(settings_path).settings.preference("claude").usage_consented


def test_enable_is_a_consent_and_disable_withdraws_it(tmp_path: Path) -> None:
    settings_path = tmp_path / "provider-usage.json"
    assert (
        provider_usage_cli.main(["enable", "grok"], stdout=io.StringIO(), home=tmp_path, settings_path=settings_path)
        == 0
    )
    assert load_provider_usage_settings(settings_path).settings.preference("grok").usage_consented
    assert (
        provider_usage_cli.main(["disable", "grok"], stdout=io.StringIO(), home=tmp_path, settings_path=settings_path)
        == 0
    )
    row = load_provider_usage_settings(settings_path).settings.preference("grok")
    assert not row.usage_consented and not row.enabled


def test_the_cli_carries_a_working_install_forward_before_it_shows_anything(tmp_path: Path) -> None:
    settings_path = tmp_path / "provider-usage.json"
    save_provider_usage_settings(default_provider_usage_settings(), settings_path)
    state = ProviderUsageState((_reading("cursor", "cursor-account-api"),), NOW, None, False)
    output = io.StringIO()
    provider_usage_cli.main(
        ["status"], stdout=output, home=tmp_path, settings_path=settings_path, state_loader=lambda: state
    )
    assert "Cursor · Weekly 40% left" in output.getvalue()


# --- the words ----------------------------------------------------------------------------------


def test_every_provider_has_a_plain_disclosure_that_names_who_is_asked() -> None:
    assert {item.provider_id for item in usage_disclosures()} == set(PROVIDERS)
    for item in usage_disclosures():
        assert item.question == f"Show {item.label} usage?"
        assert item.summary.startswith("JR-Bar will ask")
        assert item.summary.endswith(("Nothing else is sent.", "Nothing leaves your Mac."))
        assert item.credential
        assert item.detail
        for host in item.hosts:
            assert host in item.detail, f"{item.provider_id} detail must name {host}"
    assert usage_disclosure("claude").summary == (
        "JR-Bar will ask Anthropic for your usage with the sign-in Claude Code already has. Nothing else is sent."
    )
    assert usage_disclosure("antigravity").hosts == (), "nothing leaves the Mac for Antigravity"


def test_the_disclosed_hosts_are_the_hosts_the_collectors_use() -> None:
    import re

    source = Path(__file__).resolve().parents[1] / "src" / "jrbar"
    text = "\n".join(
        (source / name).read_text(encoding="utf-8") for name in ("provider_usage_collectors.py", "claude_quota.py")
    )
    # These x.ai realms are auth.json key namespaces, not contacted hosts.
    credential_realms = {"auth.x.ai", "accounts.x.ai"}
    used = set(re.findall(r"https://([a-z0-9.-]+)", text)) - credential_realms
    declared = {host for item in usage_disclosures() for host in item.hosts}
    assert used <= declared, f"a host is asked that no disclosure names: {sorted(used - declared)}"
    assert usage_consent_row(default_provider_usage_settings().preference("cursor"))["hosts"] == ["cursor.com"]


def test_factory_disclosure_distinguishes_explicit_key_check_from_ongoing_usage() -> None:
    detail = usage_disclosure("factory").detail
    assert "saved API key first" in detail
    assert "your connected browser sign-in" in detail
    assert "If you approve renewal in Connect Factory" in detail
    assert "refresh token to api.workos.com" in detail
    assert "saves rotated tokens only in Keychain" in detail
    assert "Factory may ask you to sign in again in your browser" in detail
    assert "Connecting does not turn on usage" in detail
    assert "Save API key checks a key once" in detail
    assert "this switch controls ongoing requests" in detail
    assert usage_disclosure("factory").hosts == ("api.factory.ai", "api.workos.com")
    assert "leaves token renewal to the browser" not in detail


# --- the cross-Mac usage sync is off on a fresh install too -------------------------------------


def test_usage_sync_between_macs_is_off_on_a_fresh_install(tmp_path: Path) -> None:
    from jrbar.provider_usage_sync_settings import (
        default_provider_sync_settings,
        load_provider_sync_settings,
    )

    assert default_provider_sync_settings().enabled is False
    assert load_provider_sync_settings(tmp_path / "missing.json").settings.enabled is False
    junk = tmp_path / "provider-sync.json"
    junk.write_text(json.dumps({"enabled": True}), encoding="utf-8")
    # Enabled without a device id is refused, so a stray document cannot turn it on.
    assert load_provider_sync_settings(junk).settings.enabled is False
