from datetime import datetime, timezone
from pathlib import Path

import pytest

from jrbar.models import AgentMode, AgentStatus, HookEvent
from jrbar.provider_ids import PROVIDER_ALIASES, canonical_provider_id
from jrbar.t3_compat import _normalize_provider
from scripts.gen_provider_ids import OUTPUT, generated


@pytest.mark.parametrize("provider,alias", [(key, alias) for key, aliases in PROVIDER_ALIASES.items() for alias in aliases])
def test_every_explicit_alias_is_canonical_at_ingress_and_t3(provider, alias):
    now = datetime(2026, 10, 7, tzinfo=timezone.utc)
    assert canonical_provider_id("  " + alias.upper() + "  ") == provider
    assert HookEvent(alias, now, "UserPromptSubmit", {}, session_id="fixture").status_key == f"{provider}:session:fixture"
    status = AgentStatus(alias, f"{alias}:session:fixture", "Fixture", AgentMode.WORKING, now, "UserPromptSubmit")
    assert status.provider == provider
    assert status.agent_id == f"{provider}:session:fixture"
    assert _normalize_provider(alias) == provider


def test_custom_labels_and_model_names_do_not_claim_a_provider():
    for value in ("my-claude-account", "claude-sonnet-4-6", "acpRegistry_devin", "new-provider"):
        assert canonical_provider_id(value) == value.lower()
        assert _normalize_provider(value, "claude") == "other"
    assert canonical_provider_id("openai-api") != canonical_provider_id("openai")


def test_app_fallback_is_generated_from_the_daemon_table():
    assert OUTPUT.read_text() == generated()
    assert Path(OUTPUT).is_file()
