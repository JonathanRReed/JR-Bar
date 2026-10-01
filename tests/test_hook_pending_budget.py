"""The startup drain of the shim's spool is bounded; the rest continues on a worker.

After a long outage the spool can hold 5000 lines per provider file, and each
line costs about 4 ms (the hook is normalized and appended to the log with an
fsync): a launch that drained it all before opening its sockets was deaf for
about 21 s per provider, to the app and to every live hook. The launch drain
now stops at a time budget, the sockets open, and the worker the drainer
already runs finishes the same pass -- the same files, the same lines, the same
order. Live hooks that arrive meanwhile are accepted but held behind it, so a
spooled prompt can never land on top of the Stop that followed it.

Everything is driven by an injected clock and events: no sleeps.
"""

from __future__ import annotations

import json
import threading
import time
from pathlib import Path

import pytest

from jrbar.hook_ingress import HookIngressService
from jrbar.hook_ingress_protocol import HookIngressRequest
from jrbar.hook_pending import (
    PENDING_STARTUP_BUDGET_SECONDS,
    PENDING_SUFFIX,
    PendingHookDrainer,
    drain_pending_hooks,
    pending_hook_files,
)
from tests.test_core_runtime import _FakeDrainer, headless  # noqa: F401  (the headless daemon fixture)

# Bounds a hang, never a slow machine.
WAIT = 30.0


class _Clock:
    """The drainer's monotonic clock: it moves only when a test moves it."""

    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def _spool(directory: Path, provider: str, count: int) -> None:
    rows = [
        json.dumps(
            {
                "provider": provider,
                "queued_at_ms": int(time.time() * 1000) - 5_000 + number,
                "payload": json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s", "n": number}),
            }
        )
        for number in range(count)
    ]
    (directory / f"{provider}{PENDING_SUFFIX}").write_text("\n".join(rows) + "\n")


def _seen(requests: list[HookIngressRequest]) -> list[tuple[str, int]]:
    return [(request.provider, json.loads(request.payload_text)["n"]) for request in requests]


def _remaining_files(directory: Path) -> list[str]:
    return sorted(path.name for path in directory.iterdir() if "pending" in path.name)


class _Hold:
    """What the launch hands the drainer to hold and release live hooks."""

    def __init__(self) -> None:
        self.held = 0
        self.released = threading.Event()
        self.released_count = 0

    def hold(self) -> None:
        self.held += 1

    def release(self) -> None:
        self.released_count += 1
        self.released.set()


def _drainer(directory: Path, submit, clock: _Clock, hold: _Hold, **kwargs) -> PendingHookDrainer:
    return PendingHookDrainer(
        submit,
        state_dir=directory,
        clock=clock,
        hold_live=hold.hold,
        release_live=hold.release,
        **kwargs,
    )


def test_the_first_pass_stops_at_its_budget_and_the_worker_finishes_the_rest_in_order(tmp_path: Path) -> None:
    _spool(tmp_path, "claude", 5)
    _spool(tmp_path, "codex", 3)
    clock = _Clock()
    seen: list[HookIngressRequest] = []
    flushed: list[int] = []

    def submit(request: HookIngressRequest) -> None:
        seen.append(request)
        clock.now += 1.0  # each line costs a second of the injected clock

    hold = _Hold()
    drainer = _drainer(
        tmp_path, submit, clock, hold, first_pass_budget_seconds=3.0, after_drain=lambda: flushed.append(len(seen))
    )
    # The launch's synchronous pass: three lines, then it hands the rest over.
    assert drainer.drain_now() == 3
    assert _seen(seen) == [("claude", 0), ("claude", 1), ("claude", 2)]
    assert hold.held == 1 and hold.released_count == 0
    assert flushed == [3], "what the slice wrote reaches the monitor before the sockets open"
    # The unfinished file stays on disk under its draining name, so a crash
    # here leaves it to be adopted, and nothing is queued twice.
    assert any(".draining-" in name for name in _remaining_files(tmp_path))

    # The worker finishes the same pass: the same files in the same order.
    drainer.start()
    try:
        assert hold.released.wait(WAIT), "the live hooks were never released"
    finally:
        drainer.stop()
    assert _seen(seen) == [("claude", n) for n in range(5)] + [("codex", n) for n in range(3)]
    assert hold.held == 1 and hold.released_count == 1
    assert flushed[-1] == 8
    assert _remaining_files(tmp_path) == []


def test_a_drain_that_fits_its_budget_holds_nothing(tmp_path: Path) -> None:
    _spool(tmp_path, "claude", 3)
    clock = _Clock()
    seen: list[HookIngressRequest] = []

    def submit(request: HookIngressRequest) -> None:
        seen.append(request)
        clock.now += 1.0

    hold = _Hold()
    drainer = _drainer(tmp_path, submit, clock, hold, first_pass_budget_seconds=60.0)
    assert drainer.drain_now() == 3
    assert hold.held == 0 and hold.released_count == 0
    assert _remaining_files(tmp_path) == []
    # Only the first pass is budgeted: the next one, with a backlog, runs whole.
    _spool(tmp_path, "claude", 4)
    assert drainer.drain_now() == 4
    assert hold.held == 0


def test_without_a_budget_the_drain_is_whole_as_before(tmp_path: Path) -> None:
    _spool(tmp_path, "claude", 4)
    seen: list[HookIngressRequest] = []
    drainer = PendingHookDrainer(seen.append, state_dir=tmp_path)
    assert drainer.drain_now() == 4
    assert _seen(seen) == [("claude", n) for n in range(4)]
    assert _remaining_files(tmp_path) == []


def test_stopping_the_worker_mid_pass_puts_what_is_left_back_in_order(tmp_path: Path) -> None:
    _spool(tmp_path, "claude", 6)
    clock = _Clock()
    seen: list[HookIngressRequest] = []
    drainer_box: list[PendingHookDrainer] = []

    def submit(request: HookIngressRequest) -> None:
        seen.append(request)
        clock.now += 1.0
        if json.loads(request.payload_text)["n"] == 3:
            # The daemon is told to stop while the worker is mid-pass.
            drainer_box[0].stop(timeout_seconds=0.0)

    hold = _Hold()
    drainer = _drainer(tmp_path, submit, clock, hold, first_pass_budget_seconds=2.0)
    drainer_box.append(drainer)
    assert drainer.drain_now() == 2
    drainer.start()
    assert hold.released.wait(WAIT)
    assert _seen(seen) == [("claude", n) for n in range(4)]
    # Nothing lost: the lines the worker never reached are pending again, in
    # order, and the file it was draining is gone.
    assert _remaining_files(tmp_path) == [f"claude{PENDING_SUFFIX}"]
    later: list[HookIngressRequest] = []
    assert drain_pending_hooks(later.append, state_dir=tmp_path) == 2
    assert _seen(later) == [("claude", 4), ("claude", 5)]
    assert _remaining_files(tmp_path) == []


def test_stopping_before_the_worker_starts_loses_nothing_and_lets_live_hooks_go(tmp_path: Path) -> None:
    _spool(tmp_path, "claude", 4)
    clock = _Clock()
    seen: list[HookIngressRequest] = []

    def submit(request: HookIngressRequest) -> None:
        seen.append(request)
        clock.now += 1.0

    hold = _Hold()
    drainer = _drainer(tmp_path, submit, clock, hold, first_pass_budget_seconds=1.0)
    assert drainer.drain_now() == 1
    drainer.stop()
    assert hold.released_count == 1
    assert _remaining_files(tmp_path) == [f"claude{PENDING_SUFFIX}"]
    later: list[HookIngressRequest] = []
    assert drain_pending_hooks(later.append, state_dir=tmp_path) == 3
    assert _seen(seen + later) == [("claude", n) for n in range(4)]


def test_a_line_whose_submit_fails_is_requeued_across_the_handoff(tmp_path: Path) -> None:
    _spool(tmp_path, "claude", 4)
    clock = _Clock()
    seen: list[HookIngressRequest] = []

    def submit(request: HookIngressRequest) -> None:
        clock.now += 1.0
        if json.loads(request.payload_text)["n"] in (0, 2):
            raise RuntimeError("could not write the log")
        seen.append(request)

    hold = _Hold()
    drainer = _drainer(tmp_path, submit, clock, hold, first_pass_budget_seconds=1.0)
    assert drainer.drain_now() == 0  # line 0 failed inside the slice
    drainer.start()
    try:
        assert hold.released.wait(WAIT)
    finally:
        drainer.stop()
    assert _seen(seen) == [("claude", 1), ("claude", 3)]
    kept = [json.loads(json.loads(line)["payload"])["n"] for line in (tmp_path / f"claude{PENDING_SUFFIX}").read_text().splitlines()]
    assert kept == [0, 2], "a failed line is kept for the next pass, in order"
    assert pending_hook_files(tmp_path) == [tmp_path / f"claude{PENDING_SUFFIX}"]


class _Interrupted(BaseException):
    """Not an Exception: what a submit that is torn down mid-line raises."""


def test_an_interrupt_in_the_middle_of_a_line_puts_that_line_back_with_the_rest(tmp_path: Path) -> None:
    """The line being submitted when the pass is torn down was not delivered:
    it goes back to the pending file with everything after it (the token
    dedupe makes a line that did land harmless to replay)."""
    _spool(tmp_path, "claude", 5)
    clock = _Clock()
    seen: list[HookIngressRequest] = []
    flushed: list[int] = []

    def submit(request: HookIngressRequest) -> None:
        clock.now += 1.0
        if json.loads(request.payload_text)["n"] == 2:
            raise _Interrupted
        seen.append(request)

    hold = _Hold()
    drainer = _drainer(
        tmp_path, submit, clock, hold, first_pass_budget_seconds=100.0, after_drain=lambda: flushed.append(len(seen))
    )
    with pytest.raises(_Interrupted):
        drainer.drain_now()
    assert _seen(seen) == [("claude", 0), ("claude", 1)]
    assert flushed == [2], "what landed still reaches the monitor"
    assert hold.held == 0 and hold.released_count == 0
    assert _remaining_files(tmp_path) == [f"claude{PENDING_SUFFIX}"]
    later: list[HookIngressRequest] = []
    assert drain_pending_hooks(later.append, state_dir=tmp_path) == 3
    assert _seen(later) == [("claude", 2), ("claude", 3), ("claude", 4)]
    assert _remaining_files(tmp_path) == []


def test_an_interrupt_in_the_workers_continuation_puts_the_line_back_and_lets_live_hooks_go(
    tmp_path: Path,
) -> None:
    _spool(tmp_path, "claude", 5)
    clock = _Clock()
    seen: list[HookIngressRequest] = []

    def submit(request: HookIngressRequest) -> None:
        clock.now += 1.0
        if json.loads(request.payload_text)["n"] == 3:
            raise _Interrupted
        seen.append(request)

    hold = _Hold()
    drainer = _drainer(tmp_path, submit, clock, hold, first_pass_budget_seconds=2.0)
    assert drainer.drain_now() == 2
    # The worker thread dies with the interrupt, as a thread does; the line it
    # was on and the rest are back on disk, and the live hooks are released.
    previous = threading.excepthook
    threading.excepthook = lambda _args: None
    try:
        drainer.start()
        assert hold.released.wait(WAIT)
    finally:
        threading.excepthook = previous
        drainer.stop()
    assert _seen(seen) == [("claude", 0), ("claude", 1), ("claude", 2)]
    later: list[HookIngressRequest] = []
    assert drain_pending_hooks(later.append, state_dir=tmp_path) == 2
    assert _seen(later) == [("claude", 3), ("claude", 4)]


def test_the_startup_budget_is_short_enough_to_open_the_sockets_promptly() -> None:
    assert 0.5 <= PENDING_STARTUP_BUDGET_SECONDS <= 3.0


# --- live hooks wait behind the backlog ---------------------------------------


class _Gate(threading.Event):
    """The hold: an Event that says when the ingress worker starts waiting on
    it, and can let an injected clock move while it waits."""

    def __init__(self, on_wait=None) -> None:
        super().__init__()
        self.waiting = threading.Event()
        self._on_wait = on_wait

    def wait(self, timeout: float | None = None) -> bool:
        self.waiting.set()
        if self._on_wait is not None:
            self._on_wait()
        return super().wait(0.0 if self._on_wait is not None else timeout)


def _request(provider: str = "claude", **fields: object) -> HookIngressRequest:
    document = {"hook_event_name": "Stop", "session_id": "s", **fields}
    return HookIngressRequest(provider, "/tmp/jrbar-test.jsonl", json.dumps(document))


def _service(tmp_path: Path, process, gate: threading.Event | None, **kwargs) -> HookIngressService:
    return HookIngressService(
        process=process,
        socket_path=tmp_path / "hook-ingress.sock",
        rejection_path=tmp_path / "rejections.jsonl",
        backlog_cleared=lambda: None,
        hold_until=gate,
        **kwargs,
    )


def test_live_hooks_are_accepted_but_wait_behind_the_backlog_in_order(tmp_path: Path) -> None:
    gate = _Gate()
    order: list[str] = []
    service = _service(tmp_path, lambda request: order.append(f"live:{json.loads(request.payload_text)['n']}"), gate)
    try:
        for number in (1, 2):
            assert service.submit(_request(n=number)).value == "accepted"
        assert gate.waiting.wait(WAIT)
        assert order == [], "a live hook was processed ahead of the backlog"
        order.append("backlog done")  # what the drainer's worker does before it releases
        gate.set()
        assert service.wait_idle(timeout_seconds=WAIT)
        assert order == ["backlog done", "live:1", "live:2"]
    finally:
        assert service.close(timeout_seconds=WAIT)


def test_a_live_hook_that_arrives_mid_handoff_lands_after_the_whole_backlog(tmp_path: Path) -> None:
    """The real drainer and the real service joined the way the launch joins
    them: the live Stop is accepted between the budgeted slice and the
    worker's continuation, and is processed after every spooled line."""
    spool = tmp_path / "spool"
    spool.mkdir()
    _spool(spool, "claude", 5)
    gate = _Gate()
    gate.set()
    order: list[str] = []
    clock = _Clock()

    def replay(request: HookIngressRequest) -> None:
        order.append(f"spool:{json.loads(request.payload_text)['n']}")
        clock.now += 1.0

    drainer = PendingHookDrainer(
        replay,
        state_dir=spool,
        clock=clock,
        first_pass_budget_seconds=2.0,
        hold_live=gate.clear,
        release_live=gate.set,
    )
    service = _service(tmp_path, lambda _request: order.append("live"), gate)
    try:
        assert drainer.drain_now() == 2
        assert not gate.is_set(), "the live hooks are held behind the rest"
        assert service.submit(_request()).value == "accepted"
        assert gate.waiting.wait(WAIT)
        drainer.start()
        assert service.wait_idle(timeout_seconds=WAIT)
        assert order == [f"spool:{n}" for n in range(5)] + ["live"]
        assert gate.is_set()
    finally:
        drainer.stop()
        assert service.close(timeout_seconds=WAIT)


def test_a_hook_that_asks_to_be_held_is_not_parked_while_the_backlog_drains(tmp_path: Path) -> None:
    """The ask would sit unseen behind the backlog until its hold lapsed, so
    the agent's own prompt is not delayed behind a hook that cannot be
    answered: no hold, the ordinary reply, the prompt appears at once."""
    from jrbar.answer_decisions import DecisionBroker

    broker = DecisionBroker(watching=lambda _facts, _pid: False)
    gate = threading.Event()
    service = _service(tmp_path, lambda _request: None, gate, decision_broker=broker)
    ask = HookIngressRequest(
        "claude",
        "/tmp/jrbar-test.jsonl",
        json.dumps(
            {
                "hook_event_name": "PermissionRequest",
                "session_id": "s",
                "tool_name": "Bash",
                "tool_input": {"command": "npm test"},
            }
        ),
        ppid=4242,
        decide_ms=50_000,
    )
    assert service._park_decision(ask) is None, "parked while the backlog drained"
    gate.set()
    assert service._park_decision(ask) is not None, "the control request was not parked"


def test_closing_the_service_does_not_wait_on_the_backlog(tmp_path: Path) -> None:
    gate = _Gate()
    processed: list[int] = []
    service = _service(tmp_path, lambda _request: processed.append(1), gate)
    service.submit(_request())
    assert gate.waiting.wait(WAIT)
    # The daemon is shutting down with the backlog unfinished: the worker
    # lets go of the hold, and close returns well inside its bound.
    assert service.close(timeout_seconds=WAIT)
    assert processed == [1]


def test_the_hold_has_a_limit_so_a_stuck_drain_cannot_starve_live_hooks(tmp_path: Path) -> None:
    clock = {"now": 0.0}

    def pass_the_limit() -> None:
        # The first look at the hold lets ten thousand injected seconds pass.
        clock["now"] = 10_000.0

    gate = _Gate(on_wait=pass_the_limit)
    processed = threading.Event()
    service = _service(tmp_path, lambda _request: processed.set(), gate, monotonic=lambda: clock["now"])
    try:
        service.submit(_request())
        assert processed.wait(WAIT), "a hold that outlived its limit still held the hook"
        assert not gate.is_set(), "the hold was never released, only given up on"
    finally:
        assert service.close(timeout_seconds=WAIT)


def test_the_hold_limit_belongs_to_the_hold_not_to_each_hook(tmp_path: Path) -> None:
    """A hold that is never released ends once, 300 s after it began: the
    second hook does not wait its own 300 s behind the first."""
    from jrbar.hook_ingress import HOOK_BACKLOG_HOLD_LIMIT_SECONDS

    clock = {"now": 0.0}
    waits = {"count": 0}

    def look_at_the_hold() -> None:
        # Each look at the hold lets two thirds of the limit pass.
        waits["count"] += 1
        clock["now"] += HOOK_BACKLOG_HOLD_LIMIT_SECONDS * 2 / 3

    gate = _Gate(on_wait=look_at_the_hold)
    waits_when_processed: list[int] = []
    both = threading.Event()

    def process(_request: HookIngressRequest) -> None:
        waits_when_processed.append(waits["count"])
        if len(waits_when_processed) == 2:
            both.set()

    service = _service(tmp_path, process, gate, monotonic=lambda: clock["now"])
    try:
        service.submit(_request(n=1))
        service.submit(_request(n=2))
        assert both.wait(WAIT)
        # The first hook looked twice (two thirds, then past the limit); the
        # second looked never. A per-hook limit would have made it four.
        assert waits_when_processed == [2, 2]
        # And once the hold has expired it holds nothing else either.
        assert service._backlog_held() is False
        assert not gate.is_set()
    finally:
        assert service.close(timeout_seconds=WAIT)


def test_a_released_hold_starts_its_limit_afresh(tmp_path: Path) -> None:
    gate = _Gate()
    clock = {"now": 0.0}
    processed = threading.Event()
    service = _service(tmp_path, lambda _request: processed.set(), gate, monotonic=lambda: clock["now"])
    try:
        service.submit(_request())
        assert gate.waiting.wait(WAIT)
        gate.set()
        assert processed.wait(WAIT)
        # Released: nothing is held, and nothing is remembered as expired.
        assert service._backlog_held() is False
        assert service._hold_started is None and service._hold_expired is False
    finally:
        assert service.close(timeout_seconds=WAIT)


def test_a_service_with_no_hold_is_unchanged(tmp_path: Path) -> None:
    processed: list[int] = []
    service = _service(tmp_path, lambda _request: processed.append(1), None)
    try:
        service.submit(_request())
        assert service.wait_idle(timeout_seconds=WAIT)
        assert processed == [1]
    finally:
        assert service.close(timeout_seconds=WAIT)


# --- the launch wires it ------------------------------------------------------


def test_the_launch_bounds_its_drain_and_hands_the_ingress_the_hold(
    headless, monkeypatch: pytest.MonkeyPatch  # noqa: F811
) -> None:
    from jrbar import core_runtime

    built: list[dict] = []

    class RecordingDrainer(_FakeDrainer):
        def __init__(self, submit, **kwargs) -> None:
            super().__init__(submit, **kwargs)
            built.append(kwargs)

    monkeypatch.setattr(core_runtime, "PendingHookDrainer", RecordingDrainer)
    controller = headless
    gate_at_ingress: list[threading.Event | None] = []
    controller.start_event_server.side_effect = lambda: gate_at_ingress.append(
        getattr(controller, "_core_backlog_gate", None)
    )
    controller.applicationDidFinishLaunching_(None)

    assert len(built) == 1
    options = built[0]
    assert options["first_pass_budget_seconds"] == PENDING_STARTUP_BUDGET_SECONDS
    gate = gate_at_ingress[0]
    assert isinstance(gate, threading.Event), "the ingress is built without the hold"
    assert gate.is_set(), "no backlog held, no hold"
    # The drainer's two callbacks are the gate: held clears it, released sets it.
    options["hold_live"]()
    assert not gate.is_set()
    options["release_live"]()
    assert gate.is_set()


def test_the_legacy_ingress_start_hands_the_service_the_launch_hold() -> None:
    """The service the daemon builds reads the hold the launch made."""
    source = (Path(__file__).resolve().parents[1] / "src" / "jrbar" / "status_bar_legacy.py").read_text()
    start = source.split("def start_hook_ingress(self)", 1)[1].split("\n    def ", 1)[0]
    assert 'hold_until=getattr(self, "_core_backlog_gate", None)' in start
