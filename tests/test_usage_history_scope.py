"""Provider-wide transcript totals do not borrow quota account identity."""

import threading
from types import SimpleNamespace

import pytest

from jrbar.core_runtime import _cmd_usage_history
from jrbar.core_usage_history import usage_history_document


@pytest.mark.parametrize("reverse", [False, True])
def test_history_command_does_not_attribute_totals_to_first_named_account(reverse):
    accounts = [
        {"id": "claude", "instance": "work", "state": "ready", "account": {"label": "Work", "plan": "Team"}},
        {"id": "claude", "instance": "personal", "state": "ready", "account": {"label": "Personal", "plan": "Pro"}},
    ]
    calls = []

    class History:
        def document(self, provider, range_name, *, budget=None, **metadata):
            assert budget == 0
            calls.append((provider, range_name, metadata))
            return usage_history_document(
                [("claude", "fixture", "claude-sonnet-4-5", 1800000000.0, 100, 0, 0, 20, "record")],
                provider=provider, range_name=range_name, now=1800000000.0, **metadata,
            )

    controller = SimpleNamespace(
        settings=SimpleNamespace(token_history_enabled=True),
        _core_lock=threading.RLock(),
        _core_documents={"state": {"usage": {"providers": list(reversed(accounts)) if reverse else accounts}}},
        _core_usage_history_service=History(),
    )
    result = _cmd_usage_history(controller, {"provider": "claude", "range": "7d"})
    assert result["account"] is None
    assert result["provider"] == "claude" and result["range"] == "7d"
    assert result["records"] == 1
    assert sum(day["tokens_in"] for day in result["days"]) == 100
    assert result["pricing"] is not None
    assert "account" not in calls[0][2]
