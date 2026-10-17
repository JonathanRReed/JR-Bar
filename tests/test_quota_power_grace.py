from __future__ import annotations

from types import SimpleNamespace

from test_keep_awake_lease import NOW, _Clock, _controller, _Factory
from test_quota_power_hold import _runtime_capacity

from jrbar.capacity_types import SourceKey
from jrbar.keep_awake import (
    LEASE_INDEFINITE,
    AwakeLease,
)
from jrbar.models import AgentMode
from jrbar.provider_facts import WorkIdentifier, WorkKey
from jrbar.quota_power_hold import (
    QuotaPowerHoldCoordinator,
    quota_adjusted_work_mode,
)


def test_quota_release_starts_one_agent_grace_and_leaves_manual_lease_alone() -> None:
    event_source = SourceKey("codex", "hooks", "local", "live_agent_events")
    work_key = WorkKey(event_source, WorkIdentifier("session-1"))
    status = SimpleNamespace(
        agent_id="codex:session:session-1",
        provider="codex",
        work_key=work_key,
        mode=AgentMode.WORKING,
        is_subagent=False,
        updated_at=SimpleNamespace(timestamp=lambda: 100.0),
    )
    holds = QuotaPowerHoldCoordinator(quiet_window_seconds=45.0)
    clock = _Clock()
    factory = _Factory()
    controller = _controller(clock, factory, grace_seconds=60.0)

    def reconcile(observed_at: float, now: float) -> AgentMode:
        snapshot, context, binding = _runtime_capacity(observed_at, 0.0)
        return quota_adjusted_work_mode(
            AgentMode.WORKING,
            statuses=(status,),
            bindings_by_work={work_key: binding},
            capacity_by_provider={"codex": snapshot},
            context=context,
            coordinator=holds,
            now=now,
        )

    assert reconcile(110.0, 110.0) is AgentMode.WORKING
    assert controller.update(AgentMode.WORKING, now=110.0)
    original_process = factory.processes[-1]

    assert reconcile(120.0, 120.0) is AgentMode.WORKING
    assert reconcile(120.0, 164.9) is AgentMode.WORKING
    assert reconcile(120.0, 165.0) is AgentMode.IDLE_READY
    assert controller.update(AgentMode.IDLE_READY, now=165.0)
    assert controller.grace_until_monotonic == 225.0

    for now in (180.0, 210.0):
        assert reconcile(120.0, now) is AgentMode.IDLE_READY
        assert controller.update(AgentMode.IDLE_READY, now=now)
        assert controller.grace_until_monotonic == 225.0
        assert original_process.terminated is False

    assert reconcile(120.0, 225.0) is AgentMode.IDLE_READY
    assert controller.update(AgentMode.IDLE_READY, now=225.0) is False
    assert original_process.terminated is True

    status.updated_at = SimpleNamespace(timestamp=lambda: 200.0)
    assert reconcile(230.0, 230.0) is AgentMode.WORKING
    assert controller.update(AgentMode.WORKING, now=230.0)
    assert len(factory.processes) == 2
    controller.start_lease(AwakeLease(LEASE_INDEFINITE, NOW, None))

    assert reconcile(240.0, 240.0) is AgentMode.WORKING
    assert reconcile(240.0, 285.0) is AgentMode.IDLE_READY
    assert controller.update(AgentMode.IDLE_READY, now=285.0)
    assert controller.update(AgentMode.IDLE_READY, now=345.0)
    assert controller.lease is not None
    assert controller.agent_holding is False
    assert controller.holding_requested is True
    assert factory.processes[-1].terminated is False
