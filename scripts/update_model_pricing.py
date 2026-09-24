#!/usr/bin/env python3
"""Write src/jrbar/resources/model_pricing.json, the price snapshot the usage
estimates ship with. Run by hand; the app never fetches a price.

    scripts/update_model_pricing.py --from-table
        the snapshot from usage_stats' hand-kept table (what ships today)

    scripts/update_model_pricing.py --litellm model_prices_and_context_window.json
        the same rows, with each rate taken from LiteLLM's MIT price list
        where every LiteLLM model the row's marker names agrees on one rate.
        Download the file yourself first:
        https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json

Only the models JR-Bar prices are kept, under the table's own markers
(``opus-4-5``, ``gpt-5.6-sol``, ``3.8-flash``), so the lookup order the tests
pin never changes. ``--dry-run`` prints what would change and writes nothing.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

OUTPUT = ROOT / "src" / "jrbar" / "resources" / "model_pricing.json"
#: Which LiteLLM keys belong to which of our families.
FAMILY_KEYS = {"anthropic": ("claude",), "openai": ("gpt-",), "gemini": ("gemini",)}


def hand_tables() -> dict[str, object]:
    from jrbar import usage_stats

    return {
        "anthropic": [list(row) for row in usage_stats.HAND_MODEL_PRICING],
        "openai": [list(row) for row in usage_stats.HAND_GPT_MODEL_PRICING],
        "gemini": [list(row) for row in usage_stats.HAND_GEMINI_MODEL_PRICING],
        "cacheReadOverrides": dict(usage_stats.HAND_CACHE_READ_RATE_OVERRIDES),
        "asOf": usage_stats.PRICING_TABLE_AS_OF,
        "source": f"usage_stats hand table ({usage_stats.PRICING_TABLE_VERSION})",
    }


def _per_mtok(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value < 0:
        return None
    return round(float(value) * 1_000_000, 6)


def apply_litellm(tables: dict[str, object], litellm: dict[str, object]) -> list[str]:
    """Update each row whose marker the LiteLLM list agrees on; return the
    changes in words."""
    changes: list[str] = []
    for family, prefixes in FAMILY_KEYS.items():
        rows = tables[family]
        for row in rows:
            marker = row[0]
            rates = Counter()
            for key, entry in litellm.items():
                lowered = key.lower().rsplit("/", 1)[-1]
                if not any(prefix in lowered for prefix in prefixes) or marker not in lowered:
                    continue
                if not isinstance(entry, dict):
                    continue
                pair = (_per_mtok(entry.get("input_cost_per_token")), _per_mtok(entry.get("output_cost_per_token")))
                if None not in pair:
                    rates[pair] += 1
            if len(rates) != 1:
                continue  # no rate, or LiteLLM disagrees with itself: keep ours
            (input_rate, output_rate), _count = rates.most_common(1)[0]
            if (input_rate, output_rate) != (row[1], row[2]):
                changes.append(f"{family} {marker}: {row[1]}/{row[2]} -> {input_rate}/{output_rate}")
                row[1], row[2] = input_rate, output_rate
    return changes


def build(arguments: argparse.Namespace) -> tuple[dict[str, object], list[str]]:
    tables = hand_tables()
    changes: list[str] = []
    if arguments.litellm is not None:
        litellm = json.loads(Path(arguments.litellm).read_text(encoding="utf-8"))
        if not isinstance(litellm, dict):
            raise SystemExit("the LiteLLM file is not a JSON object")
        changes = apply_litellm(tables, litellm)
        tables["asOf"] = date.today().isoformat()
        tables["source"] = "LiteLLM model_prices_and_context_window.json (MIT), our markers"
    document = {"schemaVersion": 1, **tables}
    return document, changes


def render(document: dict[str, object]) -> str:
    """Indented JSON with each ``[marker, input, output]`` row on one line."""
    lines = ["{"]
    items = list(document.items())
    for index, (key, value) in enumerate(items):
        comma = "," if index < len(items) - 1 else ""
        if isinstance(value, list):
            lines.append(f"  {json.dumps(key)}: [")
            for row_index, row in enumerate(value):
                row_comma = "," if row_index < len(value) - 1 else ""
                lines.append(f"    {json.dumps(row)}{row_comma}")
            lines.append(f"  ]{comma}")
        else:
            lines.append(f"  {json.dumps(key)}: {json.dumps(value, sort_keys=True)}{comma}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--from-table", action="store_true")
    source.add_argument("--litellm", type=Path)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--dry-run", action="store_true")
    arguments = parser.parse_args(argv)
    document, changes = build(arguments)
    for line in changes:
        print(line)
    text = render(document)
    if arguments.dry_run:
        print(f"would write {arguments.output} ({len(changes)} change(s))")
        return 0
    arguments.output.write_text(text, encoding="utf-8")
    print(f"wrote {arguments.output} ({len(changes)} change(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
