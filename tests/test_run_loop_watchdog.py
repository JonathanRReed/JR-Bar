"""The run-loop watchdog names a stall while it happens, with a clock the
test turns by hand."""

from __future__ import annotations

import threading

from jrbar.run_loop_watchdog import RunLoopWatchdog, python_stack_of


class _Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def _watchdog(clock, **kwargs):
    posted: list[float] = []
    logged: list[str] = []
    recorded: list[float] = []
    stacks = iter(kwargs.pop("stacks", ["core_runtime.py:10 _core_lookup_extras < subprocess.py:1 run"] * 10))
    watchdog = RunLoopWatchdog(
        post=lambda: posted.append(clock()),
        log=logged.append,
        clock=clock,
        stack=lambda: next(stacks),
        in_flight=kwargs.pop("in_flight", lambda: "set_setting"),
        record=recorded.append,
        **kwargs,
    )
    return watchdog, posted, logged, recorded


def test_a_quick_run_loop_is_never_logged__and_3_more() -> None:
    # --- scenario: a_quick_run_loop_is_never_logged
    clock = _Clock()
    watchdog, posted, logged, recorded = _watchdog(clock)
    for _ in range(8):
        watchdog.tick()
        clock.now += 0.05
        watchdog.pong()
        clock.now += 0.2
    assert len(posted) == 8
    assert logged == [] and recorded == [] and watchdog.stalls == 0

    # --- scenario: a_stall_is_named_while_it_happens_and_logged_when_it_ends
    """The stack is taken once the no-op is late, not when it finally runs,
    because by then the run loop has moved on."""
    clock = _Clock()
    watchdog, posted, logged, recorded = _watchdog(
        clock, stacks=["status_bar_legacy.py:3061 refresh_ < process_registry.py:230 list_processes"]
    )
    watchdog.tick()
    for _ in range(8):
        clock.now += 0.25
        watchdog.tick()
    assert len(posted) == 1, "no second ping while the first is unanswered"
    assert logged == []
    clock.now += 0.1
    watchdog.pong()
    watchdog.tick()
    assert watchdog.stalls == 1
    assert recorded == [2100.0]
    assert logged == [
        "core: run loop stalled 2.10s in set_setting: "
        "status_bar_legacy.py:3061 refresh_ < process_registry.py:230 list_processes"
    ]
    assert len(posted) == 2

    # --- scenario: a_long_stall_is_logged_before_it_ends_and_logs_are_rate_limited
    clock = _Clock()
    watchdog, posted, logged, recorded = _watchdog(clock, in_flight=lambda: None)
    watchdog.tick()
    while clock.now < 6.0:
        clock.now += 0.25
        watchdog.tick()
    assert len(logged) == 1 and logged[0].startswith("core: run loop stalled for 5.25s and counting:")
    watchdog.pong()
    watchdog.tick()
    assert len(logged) == 1, (
        "the stall's final length lands inside the rate window: counted, not logged"
    )
    assert watchdog.stalls == 1
    # A second stall inside the rate window is counted, then named with the
    # next line that gets through.
    clock.now += 0.25
    watchdog.tick()
    clock.now += 1.0
    watchdog.tick()
    watchdog.pong()
    watchdog.tick()
    assert len(logged) == 1 and watchdog.stalls == 2
    clock.now += 40.0
    watchdog.tick()
    watchdog.pong()
    watchdog.tick()
    assert len(logged) == 2 and "(+2 stalls not logged)" in logged[1]
    # A stall already named "and counting" still gets its final length
    # once the log window has passed — "and counting" alone never says
    # how long the run loop actually ran.
    clock.now += 31.0
    watchdog.tick()
    assert len(logged) == 3 and "and counting" in logged[2]
    clock.now += 31.0
    watchdog.pong()
    watchdog.tick()
    assert len(logged) == 4
    assert logged[3].startswith("core: run loop stalled 62.")
    assert "and counting" not in logged[3]

    # --- scenario: the_stack_reader_names_the_main_threads_python_frames
    here = threading.get_ident()
    frames = python_stack_of(here).split(" < ")
    # Innermost first: the reader itself, then this test.
    assert frames[0].startswith("run_loop_watchdog.py:")
    assert frames[1].startswith("test_run_loop_watchdog.py:")
    assert frames[1].endswith(" test_a_quick_run_loop_is_never_logged__and_3_more")
    assert python_stack_of(None) == ""


def _drive(watchdog, clock, *, pings: int, answer_after: float = 0.01) -> list[float]:
    """Run whole cycles the way the thread does: step, sleep what it asks,
    with the run loop answering ``answer_after`` seconds after each post."""
    waits: list[float] = []
    for _ in range(pings):
        watchdog.tick()
        clock.now += answer_after
        watchdog.pong()
        wait = watchdog.next_wait_seconds()
        waits.append(wait)
        clock.now += max(0.0, wait - answer_after)
    return waits


def test_a_healthy_run_loop_is_pinged_a_quarter_as_often_once_it_has_proved_itself__and_2_more() -> None:
    # --- scenario: a_healthy_run_loop_is_pinged_less_often
    clock = _Clock()
    watchdog, posted, logged, recorded = _watchdog(clock, quiet_after=5)
    waits = _drive(watchdog, clock, pings=40)
    assert waits[:5] == [0.25] * 5, "the quick pace holds until the run loop has proved itself"
    assert waits[5:] == [1.0] * 35
    assert logged == [] and recorded == []
    # Forty cycles at the old fixed pace took 10 s and posted 40 pings.
    assert clock.now > 30.0 and len(posted) == 40

    # --- scenario: a_late_ping_brings_the_quick_pace_back
    clock = _Clock()
    watchdog, posted, logged, recorded = _watchdog(clock, quiet_after=3)
    _drive(watchdog, clock, pings=6)
    assert watchdog.next_wait_seconds() == 1.0
    watchdog.tick()
    clock.now += 1.0  # the run loop is stuck for a second
    watchdog.tick()   # sees the unanswered ping and takes the stack
    assert watchdog.next_wait_seconds() == 0.25, "watching a stall closely"
    clock.now += 0.2
    watchdog.pong()
    watchdog.tick()   # settles the late ping and posts the next one
    assert watchdog.stalls == 1
    assert logged and logged[0].startswith("core: run loop stalled 1.20s")
    watchdog.pong()
    assert watchdog.next_wait_seconds() == 0.25, "the quick pace is back after a stall"
    waits = _drive(watchdog, clock, pings=6)
    assert waits[:2] == [0.25] * 2 and waits[2:] == [1.0] * 4, "and it is earned again"

    # --- scenario: a_stall_is_still_named_while_it_happens_at_the_quiet_pace
    clock = _Clock()
    watchdog, posted, logged, recorded = _watchdog(
        clock, quiet_after=2, stacks=["core_runtime.py:10 refresh_ < subprocess.py:1 run"]
    )
    _drive(watchdog, clock, pings=4)
    assert watchdog.next_wait_seconds() == 1.0
    watchdog.tick()               # a ping goes out and is never answered
    clock.now += 1.0
    watchdog.tick()               # one quiet step later it is late: stack taken now
    clock.now += 5.0
    watchdog.tick()
    assert any("and counting" in line and "core_runtime.py:10 refresh_" in line for line in logged)
