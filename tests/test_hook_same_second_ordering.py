"""Hook records that land inside one second must keep their arrival order.

A pi turn posts SessionStart, UserPromptSubmit and PreToolUse within
milliseconds; a Ctrl-C'd Codex posts Interrupt and SessionEnd together.
The monitor orders records by stamp, then by a per-event rank; whole-second
stamps tied the burst and the rank decided, which dropped SessionEnd (82)
behind Interrupt (83) and would drop an instant re-prompt (20) behind Stop
(81). Stamps now carry microseconds and SessionEnd outranks the family.
"""

from __future__ import annotations

import json
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

from jrbar._collector_legacy import LiveAgentMonitor
from jrbar.hook import format_hook_payload
from jrbar.ipc import ProviderRefreshHint
from jrbar.models import AgentMode, parse_datetime
from jrbar.provider_adapters import _derived_event_token
from jrbar.provider_facts import EventToken, SourceKey

SOURCE = SourceKey("codex", "hooks", "global", "live_agent_events")


def _ago(seconds: float, *, whole: bool = False) -> str:
    """A stamp ``seconds`` before now; ``whole`` drops the fraction the way
    every record written before this fix was stamped."""
    moment = datetime.now(timezone.utc) - timedelta(seconds=seconds)
    if whole:
        return moment.strftime("%Y-%m-%dT%H:%M:%SZ")
    return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _codex_line(event_name: str, stamp: str) -> str:
    return json.dumps(
        {
            "logged_at": stamp,
            "event": {"hook_event_name": event_name, "session_id": "thread-1", "cwd": "/tmp/work"},
        }
    )


def _replay(tmp_path: Path, lines: list[str]) -> LiveAgentMonitor:
    log = tmp_path / "codex.jsonl"
    monitor = LiveAgentMonitor()
    with log.open("a") as handle:
        for index, line in enumerate(lines):
            handle.write(line + "\n")
            handle.flush()
            monitor.reconcile_refresh_hint(ProviderRefreshHint(SOURCE, EventToken(f"hint:{index}")), log_path=log)
    return monitor


def _status(monitor: LiveAgentMonitor):
    statuses = [status for status in monitor.snapshot().statuses if status.session_id == "thread-1"]
    assert len(statuses) == 1
    return statuses[0]


def test_hook_stamp_carries_microseconds() -> None:
    line = format_hook_payload("codex", "{}")
    stamp = line["logged_at"]
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z", stamp), stamp
    parsed = parse_datetime(stamp)
    assert parsed.tzinfo is not None
    assert abs((datetime.now(timezone.utc) - parsed).total_seconds()) < 5


def test_event_token_dedupes_copies_inside_one_second() -> None:
    from jrbar.provider_adapters import ProviderEventName

    def token(epoch: float) -> EventToken:
        return _derived_event_token(SOURCE, ProviderEventName.PRE_TOOL_USE, epoch, None, None, None)

    assert token(1789056116.25) == token(1789056116.75)
    assert token(1789056116.25) != token(1789056117.0)


def test_interrupt_then_session_end_in_one_second_ends_the_session(tmp_path: Path) -> None:
    # Whole-second stamps, as every record before this fix was written:
    # the rank alone must still end the session.
    start = _ago(8.0, whole=True)
    stamp = _ago(4.0, whole=True)
    monitor = _replay(
        tmp_path,
        [
            _codex_line("SessionStart", start),
            _codex_line("UserPromptSubmit", start),
            _codex_line("PreToolUse", start),
            _codex_line("Interrupt", stamp),
            _codex_line("SessionEnd", stamp),
        ],
    )
    assert _status(monitor).mode is AgentMode.COMPLETED


def test_instant_reprompt_after_stop_keeps_the_session_working(tmp_path: Path) -> None:
    monitor = _replay(
        tmp_path,
        [
            _codex_line("SessionStart", _ago(8.4)),
            _codex_line("UserPromptSubmit", _ago(8.3)),
            _codex_line("Stop", _ago(4.3)),
            _codex_line("UserPromptSubmit", _ago(4.0)),
        ],
    )
    assert _status(monitor).mode is AgentMode.WORKING
