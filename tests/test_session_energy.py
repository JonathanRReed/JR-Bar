"""Energy per session: the agent, and everything its tools started, billed
to the one session above it -- the reading no battery app can make."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from jrbar import core_power, core_runtime
from jrbar.process_registry import AgentProcessRecord
from jrbar.session_energy import (
    HEAVY_PERCENT,
    MIN_WINDOW_SECONDS,
    CpuProcess,
    SessionEnergySampler,
    bill_processes,
    energy_document,
    live_roots,
    parse_cpu_table,
    parse_cpu_time,
    sample_sessions,
)


def test_ps_cpu_time_in_every_spelling() -> None:
    assert parse_cpu_time("0:01.87") == pytest.approx(1.87)
    assert parse_cpu_time("792:28.57") == pytest.approx(792 * 60 + 28.57)
    assert parse_cpu_time("1:02:03.45") == pytest.approx(3723.45)
    assert parse_cpu_time("2-01:00:00") == pytest.approx(2 * 86_400 + 3600)
    for bad in ("", "x:10", "1:2:3:4", "a-01:00", "-1:00"):
        assert parse_cpu_time(bad) is None


def test_the_table_reads_ps_and_skips_what_it_cannot() -> None:
    table = parse_cpu_table(
        "    1     0 Sun Sep 20 10:20:55 2026      44:40.74\n"
        "  100     1 Wed Sep  9 08:47:06 2026       0:01.87\n"
        "garbage line\n"
        "  101   100 Wed Sep  9 08:47:06 2026       nope\n"
    )
    assert set(table) == {1, 100}
    assert table[100].ppid == 1 and table[100].cpu_seconds == pytest.approx(1.87)
    assert table[100].started_at_epoch is not None


def _table(*rows: tuple[int, int, float]) -> dict[int, CpuProcess]:
    return {pid: CpuProcess(pid, ppid, 1000.0, cpu) for pid, ppid, cpu in rows}


def test_each_process_is_billed_to_the_nearest_session_above_it() -> None:
    table = _table(
        (1, 0, 999.0),  # launchd: nobody's
        (10, 1, 5.0),  # ghostty
        (20, 10, 30.0),  # claude A
        (21, 20, 12.0),  # A's cargo build
        (22, 21, 8.0),  # rustc under it
        (30, 21, 4.0),  # claude B, started from A's shell
        (31, 30, 2.0),  # B's test run
    )
    billed = bill_processes({"claude:A": 20, "claude:B": 30, "codex:gone": 99}, table)
    assert billed == {"claude:A": (50.0, 3), "claude:B": (6.0, 2)}


def test_a_share_needs_two_samples_under_the_same_pid() -> None:
    first = sample_sessions({"a": 20, "b": 30}, _table((20, 1, 100.0), (30, 1, 10.0)), at=1000.0)
    second = sample_sessions(
        {"a": 20, "b": 31, "c": 40},
        _table((20, 1, 130.0), (31, 1, 11.0), (40, 1, 1.0)),
        at=1020.0,
    )
    document = energy_document(first, second, providers={"a": "claude", "b": "codex"})
    assert document["window_seconds"] == 20.0
    rows = {row["session"]: row for row in document["sessions"]}
    assert rows["a"]["cpu_percent"] == 150.0  # 30 s of CPU in 20 s: one and a half cores
    assert rows["b"]["cpu_percent"] is None  # a new pid is a new process, not a rate
    assert rows["c"]["cpu_percent"] is None
    assert rows["a"]["provider"] == "claude" and rows["c"]["provider"] is None
    assert document["sessions"][0]["session"] == "a"
    assert document["heaviest"] == "a"
    assert document["total_percent"] == 150.0


def test_nobody_is_heavy_on_a_quiet_desk_and_old_samples_are_no_window() -> None:
    first = sample_sessions({"a": 20}, _table((20, 1, 100.0)), at=1000.0)
    idle = sample_sessions({"a": 20}, _table((20, 1, 100.2)), at=1010.0)
    assert energy_document(first, idle)["heaviest"] is None
    assert energy_document(first, idle)["sessions"][0]["cpu_percent"] < HEAVY_PERCENT
    stale = sample_sessions({"a": 20}, _table((20, 1, 500.0)), at=1000.0 + 3600.0)
    document = energy_document(first, stale)
    assert document["window_seconds"] is None
    assert document["sessions"][0]["cpu_percent"] is None
    assert document["total_percent"] is None and document["heaviest"] is None


def _record(provider: str, session: str, pid: int, *, started: float = 1000.0, ended: float | None = None):
    return AgentProcessRecord(
        provider=provider,
        session_id=session,
        pid=pid,
        started_at_epoch=started,
        command="claude",
        cwd=None,
        recorded_at_epoch=started,
        ended_at_epoch=ended,
    )


def test_only_sessions_the_registry_vouches_for_are_billed() -> None:
    table = _table((20, 1, 1.0), (30, 1, 1.0), (40, 1, 1.0), (50, 1, 1.0))
    records = {
        ("claude", "live"): _record("claude", "live", 20),
        ("claude", "reused"): _record("claude", "reused", 30, started=5000.0),
        ("claude", "ended"): _record("claude", "ended", 40, ended=2000.0),
        ("devin", "shared"): _record("devin", "shared", 50),
    }
    roots, providers = live_roots(
        [
            ("claude:session:live", "claude", "live"),
            ("claude:session:reused", "claude", "reused"),
            ("claude:session:ended", "claude", "ended"),
            ("devin:session:shared", "devin", "shared"),
            ("claude:session:none", "claude", "none"),
        ],
        table,
        record_loader=lambda provider, session: records.get((provider, session)),
    )
    assert roots == {"claude:session:live": 20}
    assert providers == {"claude:session:live": "claude"}


def test_a_first_ask_waits_for_its_own_window_and_a_second_reuses_the_first() -> None:
    clock = [1000.0]
    cpu = [100.0]
    slept: list[float] = []

    def sleep(seconds: float) -> None:
        slept.append(seconds)
        clock[0] += seconds
        cpu[0] += seconds * 0.5  # half a core

    sampler = SessionEnergySampler(
        table_reader=lambda: _table((20, 1, cpu[0])),
        clock=lambda: clock[0],
        sleep=sleep,
        record_loader=lambda provider, session: _record(provider, session, 20),
    )
    first = sampler.measure([("claude:session:a", "claude", "a")])
    assert slept == [MIN_WINDOW_SECONDS]
    assert first["sessions"][0]["cpu_percent"] == 50.0
    clock[0] += 60.0
    cpu[0] += 120.0  # two cores for a minute
    second = sampler.measure([("claude:session:a", "claude", "a")])
    assert slept == [MIN_WINDOW_SECONDS]
    assert second["window_seconds"] == 60.0
    assert second["sessions"][0]["cpu_percent"] == 200.0
    assert second["heaviest"] == "claude:session:a"


def test_the_daemon_measures_its_live_main_sessions() -> None:
    statuses = (
        SimpleNamespace(agent_id="claude:session:a", provider="claude", session_id="a", stale=False, is_subagent=False),
        SimpleNamespace(agent_id="claude:agent:x", provider="claude", session_id="a", stale=False, is_subagent=True),
        SimpleNamespace(agent_id="codex:session:b", provider="codex", session_id="b", stale=True, is_subagent=False),
        SimpleNamespace(agent_id="gemini:session:c", provider="gemini", session_id=None, stale=False, is_subagent=False),
    )
    assert core_power.energy_sessions(SimpleNamespace(statuses=statuses)) == [("claude:session:a", "claude", "a")]
    asked: list[list[tuple[str, str, str]]] = []

    class Sampler:
        def measure(self, sessions):
            asked.append(list(sessions))
            return {"sessions": [], "heaviest": None}

    controller = SimpleNamespace(last_snapshot=SimpleNamespace(statuses=statuses), _core_energy_sampler=Sampler())
    assert core_runtime._cmd_session_energy(controller, {}) == {"sessions": [], "heaviest": None}
    assert asked == [[("claude:session:a", "claude", "a")]]
    assert "session_energy" in core_runtime.command_names()
