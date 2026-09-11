"""Refresh-path micro-benchmark and the single-build-per-refresh contract.

Fixed harness: the ``headless`` fixture from ``test_core_runtime`` (same
fakes), five seeded sessions (3 working, 1 ask, 1 done), a strip and a Dot
connected through ``_pro_and_dot``. The printout is the artifact -- p50/p95
of a ``refresh_`` call and how many times each refresh rebuilt the state and
lights projections. The assertions are a budget guard, not a target.
"""

from __future__ import annotations

import time
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock

from test_core_runtime import _FakeServer, _pro_and_dot

# The fixture lives in test_core_runtime; registering the module makes
# ``headless`` resolvable without an import binding the params shadow.
pytest_plugins = ("test_core_runtime",)

ITERATIONS = 50
P95_BUDGET_MS = 250.0


def _seeded_snapshot(now: float):
    """Five sessions: 3 working, 1 ask, 1 done."""
    from jrbar.capacity_types import SourceKey
    from jrbar.collector import MonitorSnapshot, aggregate_status
    from jrbar.models import AgentMode, AgentStatus
    from jrbar.provider_facts import WorkIdentifier, WorkKey

    collected_at = datetime.fromtimestamp(now, tz=timezone.utc)

    def status(agent_id, *, provider, mode, event_name, minutes_ago=0.2, stale=False):
        source = SourceKey(provider, "hooks", "local", "agent_events")
        return AgentStatus(
            provider=provider,
            agent_id=agent_id,
            display_name=agent_id.rsplit(":", 1)[-1],
            mode=mode,
            updated_at=collected_at - timedelta(minutes=minutes_ago),
            event_name=event_name,
            session_id=agent_id.rsplit(":", 1)[-1],
            cwd=f"/work/{agent_id.rsplit(':', 1)[-1]}",
            stale=stale,
            work_key=WorkKey(source, WorkIdentifier(agent_id.replace(":", "."))),
        )

    statuses = (
        status("claude:session:alpha", provider="claude", mode=AgentMode.WORKING, event_name="PostToolUse"),
        status("codex:session:beta", provider="codex", mode=AgentMode.WORKING, event_name="PostToolUse"),
        status("devin:session:gamma", provider="devin", mode=AgentMode.WORKING, event_name="heartbeat"),
        status(
            "claude:session:delta",
            provider="claude",
            mode=AgentMode.WAITING_FOR_INPUT,
            event_name="PermissionRequest",
            minutes_ago=0.1,
        ),
        status("codex:session:epsilon", provider="codex", mode=AgentMode.COMPLETED, event_name="Stop", minutes_ago=2.0, stale=True),
    )
    return MonitorSnapshot(
        aggregate=aggregate_status(statuses),
        statuses=statuses[:4],
        stale_statuses=statuses[4:],
        sources=(),
        collected_at=collected_at,
    )


def _refreshable(controller):
    """The fixture's controller with its real ``refresh_`` restored and the
    seeded snapshot, devices and virtual bar wired in."""
    snapshot = _seeded_snapshot(time.time())
    controller.monitor = SimpleNamespace(
        snapshot=lambda: snapshot,
        current_statuses_by_key=lambda: {},
        statuses_by_key={},
        note_live_sessions=lambda *_args, **_kwargs: None,
        reconcile_refresh_hint=lambda *_args, **_kwargs: None,
        ingest_record=lambda *_args, **_kwargs: None,
    )
    _pro_and_dot(controller)
    controller.virtual_status_device = MagicMock(name="virtual_status_device")
    controller.virtual_status_device._live_program_call = None
    controller.virtual_status_device.presentation_scheduler_inputs = None
    controller.virtual_status_device._enabled = False
    controller.virtual_status_device.headless = True
    # Boundaries a benchmark must not time: hardware-adjacent IO.
    controller.read_battery_snapshot = lambda: None
    controller.sync_keep_awake = MagicMock(name="sync_keep_awake")
    controller.refresh_intake_report = lambda *a, **k: None
    controller._core = _FakeServer()
    # The fixture replaced the bound method with a MagicMock; drop it so the
    # class implementation runs.
    del controller.refresh_
    return controller


def _tick(controller) -> None:
    controller._production_force_refresh = True
    controller.refresh_(None)


def test_refresh_builds_each_projection_once(headless) -> None:
    controller = _refreshable(headless)
    builds = {"state": 0, "lights": 0}
    real_build_state = type(controller)._core_build_state
    real_build_lights = type(controller)._core_build_lights

    def counted_state():
        builds["state"] += 1
        return real_build_state(controller)

    def counted_lights():
        builds["lights"] += 1
        return real_build_lights(controller)

    controller._core_build_state = counted_state
    controller._core_build_lights = counted_lights
    _tick(controller)
    assert builds == {"state": 1, "lights": 1}


def test_hardware_write_result_still_publishes_lights_immediately(headless) -> None:
    """Outside a refresh, a completed hardware write publishes at once --
    the deferral only exists inside the refresh pass."""
    from jrbar._led_status_legacy import LedDisplayState, LedStatusWrite
    from jrbar.models import AgentMode
    from jrbar.status_bar_legacy import HardwareWriteRequest, HardwareWriteResult

    controller = _refreshable(headless)
    pro = controller.status_bar_devices(remember=False)[0]
    request = HardwareWriteRequest(pro, AgentMode.WORKING, None, (), None, 0.5)
    write = LedStatusWrite(LedDisplayState.WORKING, pro.target, "#112233 500ms pulse\nrepeat", True)
    command = controller._hardware_write_command(request, 100.0)
    result = HardwareWriteResult(
        request=request,
        write=write,
        label="SidePulse Working",
        agent_display_rendered=True,
        completed_at=4.0,
    )
    before = sum(1 for kind, _ in controller._core.published if kind == "lights")
    controller._apply_hardware_write_result(command, result)
    after = sum(1 for kind, _ in controller._core.published if kind == "lights")
    assert after == before + 1


def test_refresh_skips_reaping_right_behind_the_worker(headless) -> None:
    controller = _refreshable(headless)
    reaps = []
    controller.reap_dead_agent_processes = lambda: reaps.append(time.monotonic())
    controller._liveness_worker_sweep_at = time.monotonic() - 1.0
    _tick(controller)
    assert reaps == []


def test_refresh_reaps_when_the_worker_is_stale_or_absent(headless) -> None:
    controller = _refreshable(headless)
    reaps = []
    controller.reap_dead_agent_processes = lambda: reaps.append(time.monotonic())
    controller._liveness_worker_sweep_at = time.monotonic() - 10.0
    _tick(controller)
    assert len(reaps) == 1
    controller._liveness_worker_sweep_at = None
    _tick(controller)
    assert len(reaps) == 2


def test_refresh_reads_integration_settings_once_per_change(headless, monkeypatch) -> None:
    from jrbar import _integration_settings_legacy as integ

    controller = _refreshable(headless)
    target = integ.default_integration_settings_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text('{"settings_schema_version": 5}\n')
    integ._LOAD_CACHE.clear()
    reads = []
    real_read = integ._read_document

    def counting(path):
        reads.append(path)
        return real_read(path)

    monkeypatch.setattr(integ, "_read_document", counting)
    _tick(controller)
    _tick(controller)
    assert len(reads) == 1


def test_doctor_reports_performance_and_frame_generations(headless) -> None:
    controller = _refreshable(headless)
    document = controller._core_doctor_document()
    performance = document["performance"]
    assert set(performance) == {"metrics", "cpu", "frames"}
    assert performance["cpu"]["percent_since_last"] is None
    frames = performance["frames"]
    assert frames["state_per_minute"] == 0 and frames["lights_per_minute"] == 0
    _tick(controller)
    document = controller._core_doctor_document()
    updated = document["performance"]["frames"]
    assert updated["state_generation"] == frames["state_generation"] + 1
    assert updated["lights_generation"] == frames["lights_generation"] + 1
    assert updated["state_per_minute"] == 1 and updated["lights_per_minute"] == 1
    assert document["performance"]["cpu"]["percent_since_last"] is not None


def test_refresh_budget(headless) -> None:
    controller = _refreshable(headless)
    builds = {"state": 0, "lights": 0}
    real_build_state = type(controller)._core_build_state
    real_build_lights = type(controller)._core_build_lights

    def counted_state():
        builds["state"] += 1
        return real_build_state(controller)

    def counted_lights():
        builds["lights"] += 1
        return real_build_lights(controller)

    controller._core_build_state = counted_state
    controller._core_build_lights = counted_lights

    durations = []
    for _ in range(ITERATIONS):
        controller._production_force_refresh = True
        start = time.perf_counter()
        controller.refresh_(None)
        durations.append((time.perf_counter() - start) * 1000.0)

    durations.sort()
    p50 = durations[len(durations) // 2]
    p95 = durations[max(0, int(len(durations) * 0.95) - 1)]
    print(
        f"\nrefresh p50={p50:.1f}ms p95={p95:.1f}ms over {ITERATIONS} ticks; "
        f"builds/refresh: state={builds['state'] / ITERATIONS:.1f} "
        f"lights={builds['lights'] / ITERATIONS:.1f} "
        f"(state={builds['state']} lights={builds['lights']})"
    )
    assert builds["state"] == ITERATIONS, "state projection built more than once per refresh"
    assert builds["lights"] == ITERATIONS, "lights projection built more than once per refresh"
    assert p95 < P95_BUDGET_MS, f"refresh p95 {p95:.1f}ms over the {P95_BUDGET_MS:.0f}ms guard"
