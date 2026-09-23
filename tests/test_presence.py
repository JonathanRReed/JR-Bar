"""One presence fact from the app's mic/camera sensors, used everywhere:
the quiet policy's ``call`` source, the ladder held at the light, the
Dot's "On a call" role, and the Dot turning beacon under a shut lid."""

from __future__ import annotations

from datetime import datetime
from zoneinfo import ZoneInfo

import pytest

from jrbar.dnd_controller import DndController
from jrbar.dnd_policy import (
    DndMode,
    DndSchedule,
    DndSource,
    OutboundAdmission,
    contribution_for_presence,
    evaluate_dnd_policy,
)
from jrbar.dot_role import DotBeaconFacts, plan_dot_surface
from jrbar.focus_status import FocusActivity, FocusAuthorization, FocusStatusObservation
from jrbar.presence import (
    AWAY_IDLE_SECONDS,
    PRESENCE_TTL_SECONDS,
    PresenceFacts,
    normalize_presence_quiet_mode,
    parse_presence,
    presence_document,
    presence_escalation_ceiling,
)
from jrbar.settings import AgentMonitorSettings, load_settings, save_settings
from jrbar.signals import (
    ESCALATION_TIER_CHIME,
    ESCALATION_TIER_MENU_BAR,
    presence_escalation_stage,
)

UTC = ZoneInfo("UTC")
NOW = datetime(2026, 9, 22, 15, 0, tzinfo=UTC).timestamp()


# --- the fact ------------------------------------------------------------------


def test_a_report_is_a_call_until_it_goes_stale() -> None:
    facts = parse_presence({"mic": True}, now=NOW)
    assert facts.on_call(NOW) and facts.call_since == NOW
    assert facts.on_call(NOW + PRESENCE_TTL_SECONDS - 1)
    assert not facts.on_call(NOW + PRESENCE_TTL_SECONDS)
    # A report from the future (a clock step) is not fresh either.
    assert not facts.on_call(NOW - 5)

    # A renewal keeps the call's start; a gap starts a new call.
    renewed = parse_presence({"camera": True}, now=NOW + 60, previous=facts)
    assert renewed.call_since == NOW
    later = parse_presence({"screen_shared": True}, now=NOW + 1000, previous=facts)
    assert later.call_since == NOW + 1000
    assert parse_presence({"mic": False}, now=NOW, previous=facts).call_since is None


def test_away_meeting_and_focus_hint() -> None:
    facts = parse_presence(
        {"locked": False, "idle_seconds": AWAY_IDLE_SECONDS, "focus": True, "meeting_until": NOW + 1800},
        now=NOW,
    )
    assert facts.away(NOW) and not facts.on_call(NOW)
    assert facts.focus_hint(NOW) is True
    assert facts.focus_hint(NOW + PRESENCE_TTL_SECONDS) is None
    # The meeting carries its own end and does not need the app alive.
    assert facts.in_meeting(NOW + PRESENCE_TTL_SECONDS + 10)
    assert not facts.in_meeting(NOW + 1800)
    assert parse_presence({"locked": True}, now=NOW).away(NOW)
    assert parse_presence({"meeting_until": NOW - 1}, now=NOW).meeting_until is None


@pytest.mark.parametrize(
    "args",
    [
        {"mic": "yes"},
        {"camera": 1},
        {"idle_seconds": -1},
        {"idle_seconds": "long"},
        {"focus": "on"},
        {"meeting_until": "soon"},
        {"meeting_until": NOW + 13 * 3600},
    ],
)
def test_a_malformed_report_is_refused_not_guessed(args) -> None:
    with pytest.raises(ValueError):
        parse_presence(args, now=NOW)


def test_the_presence_document_reads_one_way_for_every_surface() -> None:
    facts = parse_presence({"mic": True, "camera": True}, now=NOW)
    document = presence_document(facts, now=NOW + 5, call_quiet_mode="sounds", meeting_quiet_mode="off")
    assert document == {
        "on_call": True,
        "mic": True,
        "camera": True,
        "screen_shared": False,
        "since": NOW,
        "in_meeting": False,
        "meeting_until": None,
        "away": False,
        "fresh": True,
        "quiet": "sounds",
        "escalation_ceiling": 1,
        "celebrations_held": True,
    }
    off = presence_document(facts, now=NOW + 5, call_quiet_mode="off", meeting_quiet_mode="off")
    assert off["quiet"] == "off" and off["escalation_ceiling"] is None
    assert off["celebrations_held"] is True
    stale = presence_document(facts, now=NOW + PRESENCE_TTL_SECONDS, call_quiet_mode="sounds", meeting_quiet_mode="off")
    assert stale["on_call"] is False and stale["mic"] is False and stale["fresh"] is False
    nothing = presence_document(None, now=NOW, call_quiet_mode="sounds", meeting_quiet_mode="off")
    assert nothing["on_call"] is False and nothing["quiet"] == "off"
    meeting = presence_document(
        parse_presence({"meeting_until": NOW + 600}, now=NOW),
        now=NOW,
        call_quiet_mode="sounds",
        meeting_quiet_mode="asks_only",
    )
    assert meeting["in_meeting"] and meeting["quiet"] == "asks_only" and meeting["meeting_until"] == NOW + 600


def test_quiet_mode_words_normalize() -> None:
    assert normalize_presence_quiet_mode("ASKS_ONLY") == "asks_only"
    assert normalize_presence_quiet_mode("loud") == "sounds"
    assert normalize_presence_quiet_mode(None, "off") == "off"


def test_settings_round_trip_the_quiet_modes(tmp_path) -> None:
    defaults = AgentMonitorSettings()
    assert (defaults.call_quiet_mode, defaults.meeting_quiet_mode) == ("sounds", "off")
    path = tmp_path / "settings.json"
    document = defaults.to_dict()
    document["call_quiet_mode"] = "asks_only"
    document["meeting_quiet_mode"] = "nonsense"
    path.write_text(__import__("json").dumps(document))
    loaded = load_settings(path)
    assert loaded.call_quiet_mode == "asks_only"
    assert loaded.meeting_quiet_mode == "off"
    save_settings(loaded, path)
    assert load_settings(path).call_quiet_mode == "asks_only"


# --- the quiet policy ----------------------------------------------------------------


def test_a_call_drops_the_sounds_and_keeps_the_lights() -> None:
    sounds = contribution_for_presence(DndSource.CALL, "sounds")
    assert sounds is not None and sounds.mode is None
    assert sounds.audible_allowed is False and sounds.banner_allowed and sounds.webhook_allowed
    assert sounds.brightness_factor == 1.0
    assert contribution_for_presence(DndSource.CALL, "off") is None
    asks_only = contribution_for_presence(DndSource.CALENDAR, "asks_only")
    assert asks_only.mode is DndMode.ASKS_ONLY and asks_only.outbound_admission is OutboundAdmission.ASKS
    with pytest.raises(ValueError):
        contribution_for_presence(DndSource.MANUAL, "sounds")

    projection = evaluate_dnd_policy(
        schedule=DndSchedule(),
        override=None,
        dim_fraction=0.15,
        focus_mode=DndMode.PAUSE,
        now=NOW,
        local_timezone=UTC,
        call=sounds,
        meeting=asks_only,
        extra_transitions=(NOW + 900,),
    )
    assert projection.active_sources == (DndSource.CALL, DndSource.CALENDAR)
    assert projection.audible_allowed is False
    assert projection.summary == "DND: On a call, sounds off + In a meeting Asks Only"
    assert projection.next_transition_epoch == NOW + 900
    with pytest.raises(ValueError):
        evaluate_dnd_policy(
            schedule=DndSchedule(),
            override=None,
            dim_fraction=0.15,
            focus_mode=DndMode.PAUSE,
            now=NOW,
            local_timezone=UTC,
            call=asks_only,
        )


class _Focus:
    def __init__(self, authorization=FocusAuthorization.NOT_DETERMINED) -> None:
        self.observation = FocusStatusObservation(authorization, FocusActivity.UNAVAILABLE)

    def observe(self):
        return self.observation

    def request_authorization(self, completion) -> bool:
        return False


class _Timer:
    def __init__(self, *_args) -> None:
        pass

    def start(self) -> None:
        pass

    def cancel(self) -> None:
        pass


def _controller(settings: AgentMonitorSettings, focus: _Focus | None = None):
    holder = {"settings": settings, "now": NOW}
    projections = []
    controller = DndController(
        settings_getter=lambda: holder["settings"],
        settings_setter=lambda candidate: holder.__setitem__("settings", candidate),
        settings_saver=lambda candidate: None,
        on_projection=projections.append,
        focus_client=focus or _Focus(),
        wall_clock=lambda: holder["now"],
        timezone_getter=lambda _now: UTC,
        timer_factory=_Timer,
        recovery_timer_factory=_Timer,
    )
    controller.start()
    return controller, holder


def test_the_controller_adopts_a_call_and_lets_it_go() -> None:
    controller, holder = _controller(AgentMonitorSettings())
    assert controller.set_presence(parse_presence({"mic": True}, now=NOW)).applied
    assert controller.projection.active_sources == (DndSource.CALL,)
    assert controller.projection.audible_allowed is False

    holder["now"] = NOW + PRESENCE_TTL_SECONDS
    controller.refresh()
    assert controller.projection.active_sources == ()

    holder["settings"] = AgentMonitorSettings(call_quiet_mode="off")
    holder["now"] = NOW
    controller.set_presence(parse_presence({"mic": True}, now=NOW))
    assert controller.projection.active_sources == ()


def test_an_empty_desk_quiets_only_when_asked_to() -> None:
    controller, holder = _controller(AgentMonitorSettings())
    controller.set_presence(parse_presence({"locked": True}, now=NOW))
    # Off by default: a locked screen changes nothing on its own.
    assert controller.projection.active_sources == ()

    holder["settings"] = AgentMonitorSettings(away_quiet_mode="asks_only")
    controller.refresh()
    assert controller.projection.active_sources == (DndSource.AWAY,)
    assert controller.projection.summary == "DND: Away Asks Only"
    document = presence_document(
        parse_presence({"locked": True}, now=NOW),
        now=NOW,
        call_quiet_mode="sounds",
        meeting_quiet_mode="off",
        away_quiet_mode="asks_only",
    )
    assert document["away"] is True and document["quiet"] == "asks_only"

    # Unlocked: back to normal.
    controller.set_presence(parse_presence({"locked": False}, now=NOW))
    assert controller.projection.active_sources == ()


def test_the_apps_focus_reading_stands_in_when_the_daemon_cannot_read_focus() -> None:
    settings = AgentMonitorSettings(focus_sync_enabled=True)
    controller, holder = _controller(settings)
    controller.set_presence(parse_presence({"focus": True}, now=NOW))
    assert DndSource.MACOS_FOCUS in controller.projection.active_sources

    # The daemon's own authorized reading wins over the hint.
    authorized, _ = _controller(settings, _Focus(FocusAuthorization.AUTHORIZED))
    authorized.set_presence(parse_presence({"focus": True}, now=NOW))
    assert DndSource.MACOS_FOCUS not in authorized.projection.active_sources

    # Follow Focus off: no hint makes a Focus quiet.
    off, _ = _controller(AgentMonitorSettings())
    off.set_presence(parse_presence({"focus": True}, now=NOW))
    assert off.projection.active_sources == ()


# --- the escalation ladder -----------------------------------------------------------


def test_a_call_holds_the_ladder_at_the_light_and_away_skips_the_pulse() -> None:
    assert presence_escalation_stage(3, tier=ESCALATION_TIER_CHIME, call_ceiling=1) == 1
    assert presence_escalation_stage(2, tier=ESCALATION_TIER_CHIME, call_ceiling=1, away=True) == 1
    assert presence_escalation_stage(2, tier=ESCALATION_TIER_CHIME, away=True) == 3
    # The tier is a ceiling, never a floor.
    assert presence_escalation_stage(2, tier=ESCALATION_TIER_MENU_BAR, away=True) == 2
    assert presence_escalation_stage(1, tier=ESCALATION_TIER_CHIME, away=True) == 1
    assert presence_escalation_stage(3, tier=ESCALATION_TIER_CHIME) == 3

    facts = parse_presence({"camera": True}, now=NOW)
    assert presence_escalation_ceiling(facts, now=NOW, call_quiet_mode="sounds") == 1
    assert presence_escalation_ceiling(facts, now=NOW, call_quiet_mode="off") is None
    assert presence_escalation_ceiling(None, now=NOW, call_quiet_mode="sounds") is None


# --- the Dot ---------------------------------------------------------------------------


def test_the_call_role_is_a_steady_busylight_and_a_beacon_between_calls() -> None:
    plan = plan_dot_surface(role="call", facts=DotBeaconFacts(on_call=True, ask_count=2))
    assert plan.program == "#FF2D20" and plan.why == "on_call" and not plan.animated
    assert plan.role == "call"

    between = plan_dot_surface(role="call", facts=DotBeaconFacts(ask_count=1, escalation_stage=2))
    assert between.why == "waiting" and between.animated and between.role == "call"
    idle = plan_dot_surface(role="call", facts=DotBeaconFacts())
    assert idle.program == "off" and idle.why == "idle"


def test_a_shut_lid_turns_an_extend_dot_into_the_beacon() -> None:
    strip = "#00E5FF 1000ms cosine\noff 1000ms cosine\nrepeat"
    open_lid = plan_dot_surface(role="extend", facts=DotBeaconFacts(ask_count=1), strip_program=strip)
    assert open_lid.role == "extend"

    shut = plan_dot_surface(
        role="extend", facts=DotBeaconFacts(ask_count=1, lid_closed=True), strip_program=strip
    )
    assert shut.role == "asks" and shut.why == "waiting"
    assert "auto:lid_closed" in shut.reasons
    # Status keeps its own display whatever the lid does.
    assert plan_dot_surface(role="status", facts=DotBeaconFacts(lid_closed=True)) is None


def test_presence_facts_are_frozen() -> None:
    facts = PresenceFacts(received_at=NOW, mic=True)
    with pytest.raises(AttributeError):
        facts.mic = False  # type: ignore[misc]


# --- a ceiling per provider ----------------------------------------------------------


def test_a_provider_ceiling_only_ever_lowers_the_stage() -> None:
    from jrbar.signals import normalize_provider_escalation_tiers, provider_escalation_stage

    tiers = normalize_provider_escalation_tiers({"codex": "light", "claude": "chime", "pi": "shout", 3: "light"})
    assert tiers == {"claude": "chime", "codex": "light"}
    assert provider_escalation_stage(3, provider="codex", tiers=tiers) == 1
    assert provider_escalation_stage(2, provider="claude", tiers=tiers) == 2
    assert provider_escalation_stage(3, provider="gemini", tiers=tiers) == 3
    assert provider_escalation_stage(3, provider=None, tiers=tiers) == 3
    assert normalize_provider_escalation_tiers("codex=light") == {}


def test_the_daemon_caps_the_oldest_asks_provider() -> None:
    from types import SimpleNamespace

    from jrbar import core_power

    controller = SimpleNamespace(
        settings=AgentMonitorSettings(escalation_tier_by_provider={"codex": "light"}),
        _core_oldest_ask=lambda: SimpleNamespace(provider="codex"),
    )
    assert core_power.escalation_stage(controller, 3) == 1
    controller._core_oldest_ask = lambda: SimpleNamespace(provider="claude")
    assert core_power.escalation_stage(controller, 3) == 3
    assert AgentMonitorSettings().to_dict()["escalation_tier_by_provider"] == {}
