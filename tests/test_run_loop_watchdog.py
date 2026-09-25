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
