#!/usr/bin/env python3
"""Compare the old cached scanner and incremental index on synthetic data.

Run with the project's Python. All files and provider homes stay under a
TemporaryDirectory. CPU is process time; RSS is the worker's peak resident
memory, including imports. Corpus generation is outside the timed worker.
"""

from __future__ import annotations

import argparse
import json
import os
import resource
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


def generate(root, count):
    now = datetime(2026, 10, 25, 12, tzinfo=timezone.utc)
    for provider in ("claude", "codex"):
        folder = root / (".claude/projects" if provider == "claude" else ".codex/sessions")
        folder.mkdir(parents=True)
        for batch in range(count // 2000):
            with (folder / f"{batch:04}.jsonl").open("w") as file:
                if provider == "codex":
                    file.write(
                        json.dumps(
                            {
                                "type": "session_meta",
                                "timestamp": now.isoformat(),
                                "payload": {"id": f"synthetic-{batch}", "timestamp": now.isoformat()},
                            }
                        )
                        + "\n"
                    )
                    file.write(json.dumps({"type": "turn_context", "payload": {"model": "gpt-5.6"}}) + "\n")
                for offset in range(1000):
                    stamp = (now - timedelta(days=batch % 29, seconds=offset)).isoformat()
                    if provider == "claude":
                        row = {
                            "type": "assistant",
                            "timestamp": stamp,
                            "message": {
                                "id": f"synthetic-{batch}-{offset}",
                                "model": "claude-sonnet-4-5",
                                "usage": {
                                    "input_tokens": 100,
                                    "cache_read_input_tokens": 20,
                                    "cache_creation_input_tokens": 10,
                                    "output_tokens": 30,
                                },
                            },
                        }
                    else:
                        row = {
                            "type": "event_msg",
                            "timestamp": stamp,
                            "payload": {
                                "type": "token_count",
                                "info": {
                                    "total_token_usage": {
                                        "input_tokens": 100 * (offset + 1),
                                        "output_tokens": 30 * (offset + 1),
                                    },
                                    "last_token_usage": {"input_tokens": 100, "output_tokens": 30},
                                },
                            },
                        }
                    file.write(json.dumps(row) + "\n")


def worker(root, side, phase):
    os.environ.update(HOME=str(root), XDG_STATE_HOME=str(root / "state"), XDG_CONFIG_HOME=str(root / "config"))
    os.environ.pop("CLAUDE_CONFIG_DIR", None)
    os.environ.pop("CODEX_HOME", None)
    from jrbar import usage_stats as usage
    from jrbar.core_usage_history import usage_history_document
    from jrbar.token_history_index import TokenHistoryIndex

    now = datetime(2026, 10, 25, 12, tzinfo=timezone.utc).timestamp()
    since = usage.card_window_start(now)
    roots = {"claude": (root / ".claude/projects",), "codex": (root / ".codex/sessions",)}
    index = TokenHistoryIndex(root / "state/index.sqlite3")

    def scan():
        if side == "before":
            totals = usage.scan_usage(
                roots["claude"][0], root / "state/old.json", codex_root=roots["codex"][0], since_epoch=since, now=now
            )
        else:
            totals = index.scan(roots, since_epoch=since, now=now)
        documents = [usage_history_document(totals.records, provider=p, range_name="30d", now=now) for p in roots]
        return {
            "records": sum(d["records"] for d in documents),
            "tokens": sum(row["processed_tokens"] for d in documents for row in d["days"]),
            "cost": sum(row["cost_usd"] for d in documents for row in d["days"]),
        }

    # The parent prepares warm disk state in a separate worker so cold
    # allocations cannot inflate this worker's peak RSS.
    started = time.process_time()
    result = scan()
    result.update(
        cpu_seconds=time.process_time() - started,
        peak_rss_mib=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        / (1024 * 1024 if sys.platform == "darwin" else 1024),
    )
    print(json.dumps(result), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", nargs=3, metavar=("ROOT", "SIDE", "PHASE"))
    parser.add_argument("--records", type=int, default=200_000)
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    if args.records <= 0 or args.records % 2000 or args.runs <= 0:
        parser.error("records must be a positive multiple of 2000; runs must be positive")
    if args.worker:
        worker(Path(args.worker[0]), *args.worker[1:])
        return
    results = []
    with tempfile.TemporaryDirectory(prefix="jrbar-token-benchmark-") as folder:
        root = Path(folder)
        generate(root, args.records)
        for run in range(args.runs):
            # Alternate sides each round. Each cold scan gets an empty cache.
            for side in ("before", "after") if run % 2 == 0 else ("after", "before"):
                import shutil

                shutil.rmtree(root / "state", ignore_errors=True)
                for phase in ("cold", "warm"):
                    completed = subprocess.run(
                        [sys.executable, __file__, "--worker", str(root), side, phase],
                        text=True,
                        capture_output=True,
                        check=True,
                    )
                    row = json.loads(completed.stdout)
                    assert row["records"] == args.records, row
                    assert row["tokens"] == args.records // 2 * (160 + 130), row
                    row.update(side=side, phase=phase, run=run)
                    results.append(row)
                    print(json.dumps(row), flush=True)
    assert len({round(row["cost"], 8) for row in results}) == 1, "cost totals differ"
    for phase in ("cold", "warm"):
        for side in ("before", "after"):
            rows = [r for r in results if r["phase"] == phase and r["side"] == side]
            print(
                json.dumps(
                    {
                        "summary": f"{side} {phase}",
                        "runs": len(rows),
                        **{
                            metric: {
                                "median": statistics.median(r[metric] for r in rows),
                                "min": min(r[metric] for r in rows),
                                "max": max(r[metric] for r in rows),
                            }
                            for metric in ("cpu_seconds", "peak_rss_mib")
                        },
                    }
                ),
                flush=True,
            )


if __name__ == "__main__":
    main()
