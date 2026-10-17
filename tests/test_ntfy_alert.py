"""The phone alert: off by default, a fixed line only, and never without opt-in.

Every transport here is a fake. Nothing reaches a network, and the tests prove
that the default settings, a missing topic and an unmet away condition each
make no request at all.
"""

from __future__ import annotations

import re
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest

from jrbar import ntfy_alert
from jrbar.ntfy_alert import (
    KIND_FINISHED,
    KIND_NEEDS_YOU,
    NtfyTarget,
    PhoneAlerts,
    Reason,
    parse_target,
)
from jrbar.settings import AgentMonitorSettings
from tests.test_core_runtime import headless  # noqa: F401  (the headless daemon fixture)


class Wire:
    """A transport that records what would have left the Mac."""

    def __init__(self, status: int | None = 200) -> None:
        self.status = status
        self.sent: list[tuple[str, bytes]] = []

    def __call__(self, target: NtfyTarget, body: bytes) -> int | None:
        self.sent.append((target.url, body))
        return self.status


def _settings(**fields):
    base = {"ntfy_enabled": True, "ntfy_topic": "mac-agents-7", "ntfy_only_when_away": True}
    base.update(fields)
    return SimpleNamespace(**base)


def _service(wire: Wire, *, away: bool = True, clock=None) -> PhoneAlerts:
    ticks = iter(range(10_000, 10_000_000, 100))
    return PhoneAlerts(
        transport=wire,
        away_probe=lambda: away,
        clock=clock or (lambda: float(next(ticks))),
        spawn=lambda work: work(),
    )


# --- the settings -------------------------------------------------------------------


def test_the_defaults_are_off_with_no_topic_and_the_away_condition_on() -> None:
    settings = AgentMonitorSettings()
    assert settings.ntfy_enabled is False
    assert settings.ntfy_topic == ""
    assert settings.ntfy_only_when_away is True
    document = settings.to_dict()
    assert (document["ntfy_enabled"], document["ntfy_topic"], document["ntfy_only_when_away"]) == (False, "", True)


def test_the_settings_round_trip_and_a_mistyped_value_falls_back(tmp_path) -> None:
    from jrbar.core_runtime import settings_from_document
    from jrbar.settings import load_settings, save_settings

    target = tmp_path / "settings.json"
    chosen = replace(
        AgentMonitorSettings(),
        ntfy_enabled=True,
        ntfy_topic="  my-topic  ",
        ntfy_only_when_away=False,
    )
    save_settings(chosen, target)
    loaded = load_settings(target)
    assert (loaded.ntfy_enabled, loaded.ntfy_topic, loaded.ntfy_only_when_away) == (True, "my-topic", False)

    document = AgentMonitorSettings().to_dict()
    for mistyped in ("yes", 1, None, [True], "true"):
        broken = settings_from_document(
            {**document, "ntfy_enabled": mistyped, "ntfy_only_when_away": mistyped, "ntfy_topic": mistyped},
            scratch_dir=tmp_path,
        )
        assert broken.ntfy_enabled is False
        assert broken.ntfy_only_when_away is True
        assert broken.ntfy_topic == (mistyped if isinstance(mistyped, str) else "")
    for key in ("ntfy_enabled", "ntfy_topic", "ntfy_only_when_away"):
        document.pop(key)
    old = settings_from_document(document, scratch_dir=tmp_path)
    assert old.ntfy_enabled is False


def test_the_apps_settings_keys_are_keys_the_daemon_serves() -> None:
    catalogue = Path(__file__).parents[1] / "app" / "Sources" / "JRBarCore" / "SettingsDocument.swift"
    keys = set(re.findall(r'SettingsKey\(\.\w+, "([^"]+)", \.\w+\)', catalogue.read_text(encoding="utf-8")))
    served = AgentMonitorSettings().to_dict()
    for key in ("ntfy_enabled", "ntfy_topic", "ntfy_only_when_away"):
        assert key in keys and key in served


# --- where a line may go ------------------------------------------------------------


@pytest.mark.parametrize(
    ("value", "url"),
    [
        ("mac-agents-7", "https://ntfy.sh/mac-agents-7"),
        ("  Tidy_Topic  ", "https://ntfy.sh/Tidy_Topic"),
        ("https://ntfy.sh/mac-agents-7", "https://ntfy.sh/mac-agents-7"),
        ("https://ntfy.example.com/alerts", "https://ntfy.example.com/alerts"),
        ("https://ntfy.example.com:8443/alerts/", "https://ntfy.example.com:8443/alerts"),
    ],
)
def test_a_topic_or_an_https_address_is_a_target(value, url) -> None:
    target = parse_target(value)
    assert target is not None and target.url == url


@pytest.mark.parametrize(
    "value",
    [
        "",
        "   ",
        None,
        7,
        "a topic with spaces",
        "a/b",
        "x" * 65,
        "http://ntfy.sh/topic",
        "ftp://ntfy.sh/topic",
        "https://ntfy.sh/",
        "https://ntfy.sh/a/b",
        "https://ntfy.sh/topic?auth=secret",
        "https://ntfy.sh/topic#frag",
        "https://user:pass@ntfy.sh/topic",
        "https://ntfy.sh:8080/topic",
        "https://localhost/topic",
        "https://127.0.0.1/topic",
        "https://10.0.0.5/topic",
        "https://[::1]/topic",
    ],
)
def test_anything_else_is_not_a_target(value) -> None:
    assert parse_target(value) is None


# --- nothing is sent without opt-in -------------------------------------------------


def test_the_default_settings_send_nothing_whatever_happens() -> None:
    wire = Wire()
    service = _service(wire)
    for kind in (KIND_NEEDS_YOU, KIND_FINISHED):
        outcome = service.alert(AgentMonitorSettings(), kind, "claude")
        assert (outcome.sent, outcome.reason) == (False, Reason.OFF)
    assert wire.sent == []


def test_a_topic_without_the_switch_sends_nothing() -> None:
    wire = Wire()
    outcome = _service(wire).alert(_settings(ntfy_enabled=False), KIND_NEEDS_YOU, "claude")
    assert (outcome.sent, outcome.reason) == (False, Reason.OFF)
    assert wire.sent == []


@pytest.mark.parametrize("enabled", ["true", 1, "yes", None])
def test_only_a_real_true_turns_it_on(enabled) -> None:
    wire = Wire()
    outcome = _service(wire).alert(_settings(ntfy_enabled=enabled), KIND_FINISHED, "codex")
    assert outcome.reason == Reason.OFF and wire.sent == []


def test_the_switch_without_a_topic_sends_nothing() -> None:
    wire = Wire()
    service = _service(wire)
    assert service.alert(_settings(ntfy_topic=""), KIND_NEEDS_YOU, "claude").reason == Reason.NO_TOPIC
    assert service.alert(_settings(ntfy_topic="not a topic"), KIND_NEEDS_YOU, "claude").reason == Reason.INVALID_TARGET
    assert wire.sent == []


def test_at_the_mac_nothing_is_sent_and_away_it_is() -> None:
    wire = Wire()
    here = _service(wire, away=False)
    assert here.alert(_settings(), KIND_NEEDS_YOU, "claude").reason == Reason.AT_THE_MAC
    assert wire.sent == []
    # The app's presence report can say away on its own.
    assert here.alert(_settings(), KIND_NEEDS_YOU, "claude", presence_away=True).sent is True
    assert len(wire.sent) == 1


def test_a_probe_that_cannot_tell_does_not_send(monkeypatch) -> None:
    monkeypatch.setattr(ntfy_alert, "system_is_away", lambda *a, **k: False)
    wire = Wire()
    service = PhoneAlerts(transport=wire, away_probe=lambda: False, spawn=lambda work: work())
    assert service.alert(_settings(), KIND_FINISHED, "claude").sent is False
    assert wire.sent == []


def test_with_the_away_condition_off_a_line_goes_while_at_the_mac() -> None:
    wire = Wire()
    outcome = _service(wire, away=False).alert(_settings(ntfy_only_when_away=False), KIND_FINISHED, "codex")
    assert outcome.sent is True
    assert wire.sent == [("https://ntfy.sh/mac-agents-7", b"Codex finished")]


def test_the_system_probe_without_a_session_is_not_away(monkeypatch) -> None:
    import builtins

    real_import = builtins.__import__

    def refuse(name, *args, **kwargs):
        if name == "Quartz":
            raise ImportError("no Quartz here")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", refuse)
    assert ntfy_alert.system_is_away() is False


# --- the line itself ----------------------------------------------------------------


def test_the_line_is_fixed_and_names_only_the_agent() -> None:
    wire = Wire()
    service = _service(wire)
    assert service.alert(_settings(), KIND_NEEDS_YOU, "claude").sent
    assert service.alert(_settings(), KIND_FINISHED, "codex").sent
    assert [body for _url, body in wire.sent] == [b"Claude needs you", b"Codex finished"]


@pytest.mark.parametrize(
    "provider",
    ["", None, 7, "not-a-provider", "claude\nrm -rf /", "/Users/someone/private-project", "../../etc/passwd"],
)
def test_a_provider_the_daemon_does_not_know_is_just_an_agent(provider) -> None:
    wire = Wire()
    assert _service(wire).alert(_settings(), KIND_NEEDS_YOU, provider).sent
    assert [body for _url, body in wire.sent] == [b"An agent needs you"]


def test_an_unknown_kind_sends_nothing() -> None:
    wire = Wire()
    assert _service(wire).alert(_settings(), "failed", "claude").reason == Reason.UNKNOWN_KIND
    assert wire.sent == []


def test_the_same_line_is_not_repeated_within_twenty_seconds() -> None:
    wire = Wire()
    now = [1_000.0]
    service = _service(wire, clock=lambda: now[0])
    assert service.alert(_settings(), KIND_NEEDS_YOU, "claude").sent
    now[0] += 5
    assert service.alert(_settings(), KIND_NEEDS_YOU, "claude").reason == Reason.REPEAT
    # A different agent or a different line is its own.
    assert service.alert(_settings(), KIND_NEEDS_YOU, "codex").sent
    assert service.alert(_settings(), KIND_FINISHED, "claude").sent
    now[0] += 30
    assert service.alert(_settings(), KIND_NEEDS_YOU, "claude").sent
    assert len(wire.sent) == 4


def test_no_more_than_thirty_lines_an_hour() -> None:
    wire = Wire()
    now = [1_000.0]
    service = _service(wire, clock=lambda: now[0])
    for index in range(ntfy_alert.MAX_PER_HOUR):
        now[0] += ntfy_alert.MIN_REPEAT_SECONDS + 1
        assert service.alert(_settings(), KIND_NEEDS_YOU, "claude").sent, index
    now[0] += ntfy_alert.MIN_REPEAT_SECONDS + 1
    assert service.alert(_settings(), KIND_NEEDS_YOU, "claude").reason == Reason.BUDGET
    now[0] += 3600
    assert service.alert(_settings(), KIND_NEEDS_YOU, "claude").sent
    assert len(wire.sent) == ntfy_alert.MAX_PER_HOUR + 1


# --- the Test button ----------------------------------------------------------------


def test_the_test_button_sends_one_fixed_line_even_with_the_switch_off() -> None:
    wire = Wire()
    outcome = _service(wire, away=False).send_test(_settings(ntfy_enabled=False))
    assert (outcome.sent, outcome.reason) == (True, Reason.SENT)
    assert wire.sent == [("https://ntfy.sh/mac-agents-7", ntfy_alert.TEST_MESSAGE.encode("utf-8"))]


def test_the_test_button_needs_a_usable_topic() -> None:
    wire = Wire()
    service = _service(wire)
    assert service.send_test(_settings(ntfy_topic="")).reason == Reason.NO_TOPIC
    assert service.send_test(_settings(ntfy_topic="http://ntfy.sh/x")).reason == Reason.INVALID_TARGET
    assert wire.sent == []


@pytest.mark.parametrize(
    ("status", "reason", "sent"),
    [(200, Reason.SENT, True), (204, Reason.SENT, True), (403, Reason.REJECTED, False), (429, Reason.REJECTED, False), (None, Reason.UNREACHABLE, False)],
)
def test_the_answer_is_said_in_plain_words(status, reason, sent) -> None:
    outcome = _service(Wire(status)).send_test(_settings())
    assert (outcome.sent, outcome.reason) == (sent, reason)
    assert outcome.message and "http" not in outcome.message.lower()


def test_a_transport_that_raises_is_unreachable_not_a_crash() -> None:
    def broken(target, body):
        raise RuntimeError("boom with /Users/someone/secret")

    outcome = PhoneAlerts(transport=broken, spawn=lambda work: work()).send_test(_settings())
    assert (outcome.sent, outcome.reason) == (False, Reason.UNREACHABLE)
    assert "secret" not in outcome.message


def test_the_real_transport_refuses_to_follow_a_redirect() -> None:
    from urllib.request import Request

    handler = ntfy_alert._NoRedirects()
    request = Request("https://ntfy.sh/x")
    assert handler.redirect_request(request, None, 302, "Found", {}, "https://elsewhere.example/x") is None


# --- inside the daemon --------------------------------------------------------------


def _entry(kind, *, provider="claude"):
    from jrbar.activity_ledger import ActivityEntry

    return ActivityEntry(
        kind,
        1_800_000_000.0,
        "private-project-name",
        provider,
        subject_id="claude:session:abc",
        detail="rm -rf /Users/someone",
    )


def _arm(controller, wire: Wire, *, away: bool = True) -> None:
    controller._jrbar_phone_alerts = PhoneAlerts(
        transport=wire, away_probe=lambda: away, spawn=lambda work: work()
    )


def test_a_fresh_daemon_sends_nothing_when_an_ask_opens(headless) -> None:  # noqa: F811
    from jrbar.activity_ledger import ActivityKind

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    wire = Wire()
    _arm(controller, wire)
    assert controller.settings.ntfy_enabled is False
    controller.record_activity_entries((_entry(ActivityKind.ASKED),))
    assert wire.sent == []


def test_the_daemon_sends_the_fixed_line_after_the_person_turns_it_on(headless) -> None:  # noqa: F811
    from jrbar.activity_ledger import ActivityKind

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    wire = Wire()
    _arm(controller, wire)

    controller._core_dispatch("set_setting", {"path": "ntfy_topic", "value": "my-desk"})
    controller.record_activity_entries((_entry(ActivityKind.ASKED),))
    assert wire.sent == [], "a topic alone is not opt-in"

    controller._core_dispatch("set_setting", {"path": "ntfy_enabled", "value": True})
    controller.record_activity_entries((_entry(ActivityKind.ASKED),))
    assert wire.sent == [("https://ntfy.sh/my-desk", b"Claude needs you")]

    body = wire.sent[0][1].decode("utf-8")
    for private in ("private-project-name", "rm -rf", "/Users", "abc"):
        assert private not in body


def test_a_finished_run_sends_its_line_and_a_failure_sends_none(headless) -> None:  # noqa: F811
    from jrbar.activity_ledger import ActivityKind

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    wire = Wire()
    _arm(controller, wire)
    controller._core_dispatch("set_setting", {"path": "ntfy_topic", "value": "my-desk"})
    controller._core_dispatch("set_setting", {"path": "ntfy_enabled", "value": True})

    controller.record_activity_entries((_entry(ActivityKind.BLOCKED),))
    assert wire.sent == []
    controller.post_phone_alert(KIND_FINISHED, "codex")
    assert wire.sent == [("https://ntfy.sh/my-desk", b"Codex finished")]


def test_at_the_mac_the_daemon_sends_nothing(headless) -> None:  # noqa: F811
    from jrbar.activity_ledger import ActivityKind

    controller = headless
    controller.applicationDidFinishLaunching_(None)
    wire = Wire()
    _arm(controller, wire, away=False)
    controller._core_dispatch("set_setting", {"path": "ntfy_topic", "value": "my-desk"})
    controller._core_dispatch("set_setting", {"path": "ntfy_enabled", "value": True})
    controller.record_activity_entries((_entry(ActivityKind.ASKED),))
    assert wire.sent == []


def test_ntfy_test_goes_through_the_command_and_names_what_happened(headless) -> None:  # noqa: F811
    controller = headless
    controller.applicationDidFinishLaunching_(None)
    wire = Wire()
    _arm(controller, wire, away=False)

    empty = controller._core_dispatch("ntfy_test", {})
    assert empty["sent"] is False and empty["reason"] == "no_topic" and empty["message"]
    assert wire.sent == []

    controller._core_dispatch("set_setting", {"path": "ntfy_topic", "value": "my-desk"})
    sent = controller._core_dispatch("ntfy_test", {})
    assert sent["sent"] is True and sent["reason"] == "sent"
    assert wire.sent == [("https://ntfy.sh/my-desk", ntfy_alert.TEST_MESSAGE.encode("utf-8"))]
    assert controller.settings.ntfy_enabled is False, "testing never turns it on"
