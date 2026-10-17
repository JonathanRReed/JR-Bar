from dataclasses import replace

import pytest

from jrbar.provider_feature_settings import (
    MAX_FEATURE_IDS,
    ProviderSettingsChangeReceipt,
    project_provider_feature_settings,
)
from jrbar.provider_usage_settings import default_provider_usage_settings
from jrbar.provider_usage_sync_settings import default_provider_sync_settings


def test_feature_receipts_cover_a_large_provider_and_account_catalog():
    base = default_provider_usage_settings()
    many = replace(base, providers=base.providers + tuple(
        replace(base.preference("codex"), source_instance_id=f"synthetic-{index}")
        for index in range(106)))
    result = project_provider_feature_settings(many, default_provider_sync_settings())
    assert len(result.collection.providers) == len(base.providers) + 106
    assert "collection.codex.synthetic-105.enabled" in result.receipt.changed_feature_ids
    assert "presentation.codex.synthetic-105.reset_overlay" in result.receipt.changed_feature_ids
    assert 128 < len(result.receipt.changed_feature_ids) <= MAX_FEATURE_IDS


def test_feature_receipts_keep_a_finite_identifier_budget():
    with pytest.raises(ValueError):
        ProviderSettingsChangeReceipt(1, frozenset(f"synthetic.{index}" for index in range(MAX_FEATURE_IDS + 1)))
