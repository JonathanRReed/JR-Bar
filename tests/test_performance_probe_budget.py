import pytest

from scripts.verify_performance_budget import validate_app_feed, validate_daemon_probe


def daemon_receipt():
    return {
        "workload_valid": True, "duration_seconds": 60, "cpu_percent": 1.2,
        "rss_max_mb": 80, "loop_over_250ms": 0,
        "wakeups_per_minute": {"interrupt_wakeups": 1500},
        "workload": "idle", "messages_per_minute": {"state_delta": 2},
    }


def test_daemon_probe_headroom_is_separate_from_release_budgets():
    receipt = daemon_receipt()
    assert validate_daemon_probe(receipt) == ()
    receipt.update(cpu_percent=6, rss_max_mb=201, loop_over_250ms=1)
    assert len(validate_daemon_probe(receipt)) == 3


@pytest.mark.parametrize("field,value", [
    ("workload_valid", False), ("tracing", True), ("profiling", True),
    ("duration_seconds", 30), ("wakeups_per_minute", {"interrupt_wakeups": 10001}),
    ("messages_per_minute", {"state_delta": 9}),
])
def test_daemon_rejects_invalid_or_busy_idle_receipts(field, value):
    assert validate_daemon_probe({**daemon_receipt(), field: value})


@pytest.mark.parametrize("value", [True, float("nan"), -1, "1"])
def test_daemon_rejects_invalid_numbers(value):
    with pytest.raises(ValueError):
        validate_daemon_probe({**daemon_receipt(), "cpu_percent": value})


def test_app_feed_checks_work_done_cpu_and_retained_allocations():
    receipt = {"messages": 10000, "cpu_seconds": 2, "blocks_delta": -10, "bytes_delta": 1000}
    assert validate_app_feed(receipt) == ()
    assert validate_app_feed({**receipt, "messages": 0})
    assert validate_app_feed({**receipt, "cpu_seconds": 31})
    assert validate_app_feed({**receipt, "blocks_delta": 1001})
    assert validate_app_feed({**receipt, "bytes_delta": 2000001})
    with pytest.raises(ValueError):
        validate_app_feed({**receipt, "cpu_seconds": float("nan")})
