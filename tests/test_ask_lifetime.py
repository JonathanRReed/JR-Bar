"""The two clocks an unanswered ask lives by, and nothing else.

An ask used to read "Ask" at 59 minutes and idle at 61: four modules each
carried their own one-hour cutoff. ``ask_lifetime`` names the only two clocks
that remain -- "may be stale" and "expired unanswered" -- and every test here
moves a day without waiting a day, because nothing in the module reads one.
"""

from __future__ import annotations

import pytest

from jrbar.ask_lifetime import (
    ASK_EXPIRES_UNANSWERED_SECONDS,
    ASK_MAY_BE_STALE_SECONDS,
    STALE_ASK_PULSE_STRETCH,
    AskStanding,
    ask_age_words,
    ask_dismissal_key,
    ask_standing,
    expire_after_seconds_for,
    expire_after_seconds_from,
    stale_after_seconds_for,
    stale_after_seconds_from,
    stretch_program_durations,
)

OPENED = 1_800_000_000.0
MINUTE = 60.0
HOUR = 3_600.0
DAY = 86_400.0


def _standing(after: float, *, alive: bool, heard_after: float = 0.0, **kwargs) -> AskStanding:
    return ask_standing(
        opened_at_epoch=OPENED,
        last_activity_epoch=OPENED + heard_after,
        now_epoch=OPENED + after,
        process_alive=alive,
        **kwargs,
    )


def test_the_two_clocks_are_six_hours_and_seven_days() -> None:
    assert ASK_MAY_BE_STALE_SECONDS == 6 * HOUR
    assert ASK_EXPIRES_UNANSWERED_SECONDS == 7 * DAY


@pytest.mark.parametrize("alive", [False, True])
@pytest.mark.parametrize("after", [0.0, 59 * MINUTE, 61 * MINUTE, 6 * HOUR - 1.0])
def test_an_ask_under_six_hours_is_an_ordinary_ask__the_old_hour_is_gone(
    after: float, alive: bool
) -> None:
    # 59 and 61 minutes both read as a plain ask, with or without a process.
    assert _standing(after, alive=alive) is AskStanding.CURRENT


@pytest.mark.parametrize("alive", [False, True])
@pytest.mark.parametrize("after", [6 * HOUR, 9 * HOUR, 3 * DAY, 7 * DAY - 1.0])
def test_a_quiet_ask_past_six_hours_may_be_stale_but_is_still_an_ask(
    after: float, alive: bool
) -> None:
    assert _standing(after, alive=alive) is AskStanding.MAY_BE_STALE


def test_past_seven_days_only_a_session_with_no_process_expires() -> None:
    assert _standing(8 * DAY, alive=False) is AskStanding.EXPIRED
    assert _standing(7 * DAY, alive=False) is AskStanding.EXPIRED
    # A process the table can vouch for keeps its ask however old: never
    # closed by age alone.
    assert _standing(8 * DAY, alive=True) is AskStanding.MAY_BE_STALE
    assert _standing(365 * DAY, alive=True) is AskStanding.MAY_BE_STALE


def test_a_session_that_is_still_talking_is_not_abandoned() -> None:
    # The ask is 3 days old but its session spoke an hour ago.
    assert _standing(3 * DAY, alive=False, heard_after=3 * DAY - HOUR) is AskStanding.CURRENT
    # And 7 hours of silence after that speech makes it stale again.
    assert (
        _standing(3 * DAY, alive=False, heard_after=3 * DAY - 7 * HOUR)
        is AskStanding.MAY_BE_STALE
    )


def test_a_missing_or_nonsense_time_never_marks_or_closes_an_ask() -> None:
    for opened, heard, now in (
        (None, None, OPENED + 9 * DAY),
        (float("nan"), float("inf"), OPENED + 9 * DAY),
        ("soon", True, OPENED + 9 * DAY),
        (OPENED, OPENED, float("nan")),
    ):
        assert (
            ask_standing(
                opened_at_epoch=opened,
                last_activity_epoch=heard,
                now_epoch=now,  # type: ignore[arg-type]
                process_alive=False,
            )
            is AskStanding.CURRENT
        )


def test_one_known_time_is_enough_to_judge_by() -> None:
    standing = ask_standing(
        opened_at_epoch=None,
        last_activity_epoch=OPENED,
        now_epoch=OPENED + 8 * DAY,
        process_alive=False,
    )
    assert standing is AskStanding.EXPIRED


def test_the_settings_move_the_clocks_inside_their_bounds() -> None:
    assert stale_after_seconds_from(None) == 6 * HOUR
    assert stale_after_seconds_from(2) == 2 * HOUR
    assert stale_after_seconds_from(0.0) == 900.0  # a pause is not stale
    assert stale_after_seconds_from(10_000) == 7 * DAY
    assert stale_after_seconds_from(True) == 6 * HOUR  # a bool is not a number
    assert expire_after_seconds_from(None, stale_after_seconds=6 * HOUR) == 7 * DAY
    assert expire_after_seconds_from(2, stale_after_seconds=6 * HOUR) == 2 * DAY
    # The expiry is never before the mark.
    assert expire_after_seconds_from(1, stale_after_seconds=3 * DAY) == 3 * DAY
    assert expire_after_seconds_from(10_000, stale_after_seconds=6 * HOUR) == 90 * DAY

    class Settings:
        ask_stale_after_hours = 1.0
        ask_expire_after_days = 2.0

    assert stale_after_seconds_for(Settings()) == HOUR
    assert expire_after_seconds_for(Settings()) == 2 * DAY
    assert stale_after_seconds_for(object()) == 6 * HOUR
    assert expire_after_seconds_for(object()) == 7 * DAY


def test_a_shorter_mark_marks_sooner_and_a_shorter_expiry_closes_sooner() -> None:
    kwargs = {"stale_after_seconds": HOUR, "expire_after_seconds": 2 * DAY}
    assert _standing(30 * MINUTE, alive=False, **kwargs) is AskStanding.CURRENT
    assert _standing(2 * HOUR, alive=False, **kwargs) is AskStanding.MAY_BE_STALE
    assert _standing(3 * DAY, alive=False, **kwargs) is AskStanding.EXPIRED


def test_ages_are_said_in_words() -> None:
    assert ask_age_words(5) == "under a minute"
    assert ask_age_words(60) == "1 minute"
    assert ask_age_words(45 * MINUTE) == "45 minutes"
    assert ask_age_words(HOUR) == "1 hour"
    assert ask_age_words(9 * HOUR + 59 * MINUTE) == "9 hours"
    assert ask_age_words(47 * HOUR) == "47 hours"
    assert ask_age_words(3 * DAY) == "3 days"
    assert ask_age_words(-1) == "a while"
    assert ask_age_words(float("nan")) == "a while"


def test_the_dismissal_key_is_the_session_and_the_millisecond_it_opened() -> None:
    assert ask_dismissal_key("claude:session:a", 1_800_000_000.1234) == (
        "claude:session:a",
        1_800_000_000_123,
    )
    # A later ask on the same session is a different key.
    assert ask_dismissal_key("claude:session:a", 1_800_000_050.0) != ask_dismissal_key(
        "claude:session:a", 1_800_000_000.0
    )
    assert ask_dismissal_key("", OPENED) is None
    assert ask_dismissal_key("claude:session:a", None) is None
    assert ask_dismissal_key("claude:session:a", float("nan")) is None


def test_a_calmer_pulse_is_the_same_program_slowed_down() -> None:
    program = "off 160ms cosine\n#FF3A00 1.6s pulse\nrepeat"
    calmer = stretch_program_durations(program)
    assert calmer == "off 400ms cosine\n#FF3A00 4s pulse\nrepeat"
    assert STALE_ASK_PULSE_STRETCH == 2.5
    # Shapes and colours are untouched; per-LED lines stretch too.
    per_led = "0:#00FF10 800ms cosine\n1:#00FF10 2s pulse\nrepeat"
    assert stretch_program_durations(per_led) == "0:#00FF10 2000ms cosine\n1:#00FF10 5s pulse\nrepeat"
    assert stretch_program_durations("repeat") == "repeat"
    assert stretch_program_durations(program, factor=0.0) == program
