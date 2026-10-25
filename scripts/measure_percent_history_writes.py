"""Count successful write bytes for one synthetic hour of percent samples.

Run with the checkout's src on PYTHONPATH. All writes stay in a temporary
folder. This counts syscall payloads, not APFS dirty pages or device writes.
"""

import json
import os
import tempfile
from pathlib import Path
from unittest.mock import patch

from jrbar.provider_feature_settings import (
    ProviderInstanceRetentionPolicy,
    ProviderInstanceRetentionProjection,
)
from jrbar.usage_percent_history import append_percent_observations

NOW = 1790000000.0


def row(index):
    return dict(
        provider_id="fixture",
        source_instance_id="default",
        lane_id="weekly",
        remaining_percent=float(index % 100),
        observed_at_epoch=NOW + index * 15,
    )


def measure():
    retention = ProviderInstanceRetentionProjection(
        (ProviderInstanceRetentionPolicy("fixture", "default", 30),)
    )
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "history.jsonl"
        append_percent_observations(
            path, [row(i) for i in range(-2400, 0)],
            retention_projection=retention, now_epoch=NOW,
        )
        initial = path.stat().st_size
        counts = [0, 0]
        original = os.write

        def measured(descriptor, data):
            count = original(descriptor, data)
            counts[0] += count
            counts[1] += 1
            return count

        with patch("os.write", measured):
            for index in range(240):
                assert append_percent_observations(
                    path, [row(index)], retention_projection=retention,
                    now_epoch=NOW + index * 15,
                ) == 1
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        assert rows == [row(i) for i in range(-2400, 240)]
        return dict(initial_bytes=initial, bytes_per_synthetic_hour=counts[0],
                    writes=counts[1], rows=len(rows), failures=0)


if __name__ == "__main__":
    print(json.dumps([measure() for _ in range(5)], indent=2))
