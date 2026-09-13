from __future__ import annotations

from datetime import datetime, timezone

from jrbar.demo_sandbox import (
    DEMO_SCENARIOS,
    MAX_EVENTS,
    DemoLightMode,
    DemoSandbox,
    DemoScenario,
    available_scenarios,
)

START = datetime(2026, 8, 30, 12, 0, tzinfo=timezone.utc)


def test_catalog_exposes_named_deterministic_scenarios__and_2_more() -> None:
    # --- scenario: catalog_exposes_named_deterministic_scenarios
    names = available_scenarios()
    assert names == DEMO_SCENARIOS
    assert "overview" in names
    assert {"ask", "error", "completion", "quota", "fleet", "dnd", "low_power"} <= set(names)

    # --- scenario: same_seed_and_clock_produce_identical_run
    first = DemoSandbox(start_time=START, seed=17).run("overview")
    second = DemoSandbox(start_time=START, seed=17).run(DemoScenario.OVERVIEW)

    assert first == second
    assert first.events
    assert first.final_snapshot.at >= START

    # --- scenario: different_seed_changes_only_deterministic_fixture_values
    first = DemoSandbox(start_time=START, seed=17).run("quota")
    second = DemoSandbox(start_time=START, seed=18).run("quota")

    assert first.safety.safe_for_preview is second.safety.safe_for_preview is True
    assert first.safety.seed == 17
    assert second.safety.seed == 18
    assert first.final_snapshot.quotas



def test_overview_covers_all_requested_domains_without_side_effects__and_2_more() -> None:
    # --- scenario: overview_covers_all_requested_domains_without_side_effects
    run = DemoSandbox(start_time=START, seed=3).run("overview")
    kinds = {event.kind for event in run.events}

    assert {"agent", "ask", "error", "completion", "quota", "device", "remote_machine", "policy"} <= kinds
    assert run.safety.network_access is False
    assert run.safety.credential_access is False
    assert run.safety.hook_installation is False
    assert run.safety.hardware_writes is False
    assert run.safety.filesystem_reads is False
    assert run.safety.filesystem_writes is False
    assert run.safety.user_state_mutation is False
    assert run.safety.deterministic is True

    # --- scenario: events_are_bounded_and_strictly_ordered
    run = DemoSandbox(start_time=START, seed=1, max_events=3).run("overview")

    assert len(run.events) == 3
    assert len(run.events) <= MAX_EVENTS
    assert [event.sequence for event in run.events] == [0, 1, 2]
    assert list(run.events) == sorted(run.events, key=lambda event: (event.at, event.sequence))

    # --- scenario: ask_and_error_are_high_priority_light_states
    ask = DemoSandbox(start_time=START, seed=1).run("ask").final_snapshot
    error = DemoSandbox(start_time=START, seed=1).run("error").final_snapshot

    assert ask.light.mode is DemoLightMode.ASKING
    assert ask.light.pattern == "heartbeat"
    assert ask.light.brightness == 100
    assert error.light.mode is DemoLightMode.ERROR
    assert error.light.pattern == "blink"



def test_dnd_suppresses_courtesy_completion_but_keeps_safety_metadata__and_2_more() -> None:
    # --- scenario: dnd_suppresses_courtesy_completion_but_keeps_safety_metadata
    snapshot = DemoSandbox(start_time=START, seed=1).run("dnd").final_snapshot

    assert snapshot.dnd is True
    assert snapshot.light.suppressed is True
    assert snapshot.light.mode is DemoLightMode.SUPPRESSED
    assert snapshot.light.reason == "dnd"

    # --- scenario: low_power_clamps_light_to_calm_low_energy_output
    snapshot = DemoSandbox(start_time=START, seed=1).run("low_power").final_snapshot

    assert snapshot.low_power is True
    assert snapshot.light.brightness <= 20
    assert snapshot.light.pattern == "steady"
    assert snapshot.light.reason == "low_power"

    # --- scenario: fleet_scenario_keeps_remote_machine_and_agent_distinct
    snapshot = DemoSandbox(start_time=START, seed=2).run("fleet").final_snapshot

    assert any(machine.remote for machine in snapshot.machines)
    assert any(agent.remote for agent in snapshot.agents)
    assert any(device.machine_id == "remote-build" for device in snapshot.devices)



def test_snapshot_adapter_is_content_minimized_and_render_ready__and_2_more() -> None:
    # --- scenario: snapshot_adapter_is_content_minimized_and_render_ready
    snapshot = DemoSandbox(start_time=START, seed=2).run("ask").final_snapshot

    rows = snapshot.to_projection_rows()
    render = snapshot.to_render_input(surface="screen_bar")

    assert rows
    assert rows[0]["agent_id"]
    assert rows[0]["mode"] == "waiting_for_input"
    assert "message" not in rows[0]
    assert render.surface == "screen_bar"
    assert render.light_mode == "asking"

    # --- scenario: unknown_scenario_is_rejected_without_io
    sandbox = DemoSandbox(start_time=START, seed=0)

    try:
        sandbox.run("not-a-scenario")
    except ValueError as error:
        assert "unknown demo scenario" in str(error)
    else:
        raise AssertionError("unknown scenarios must be rejected")

    # --- scenario: demo_is_reachable_from_both_cli_surfaces
    from jrbar.cli import build_jrbar_parser, build_parser, cmd_demo

    for parser in (build_jrbar_parser(), build_parser()):
        parsed = parser.parse_args(["demo", "notification_light", "--seed", "9"])
        assert parsed.func is cmd_demo
        assert parsed.scenario == "notification_light"
        assert parsed.seed == 9

