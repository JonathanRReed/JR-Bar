#!/usr/bin/env python3
"""Reject unapproved UI literals and require the existing baseline to shrink."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = Path("scripts/design_tokens_baseline.json")
MARKER = re.compile(r"//\s*jrbar-token-exception:\s*\S.+")
NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)"
PATTERNS = {
    "font": re.compile(r"\.system\s*\(\s*size\s*:\s*" + NUMBER),
    "colour": re.compile(r"\bColor\s*\(\s*(?:\.sRGB\s*,\s*)?red\s*:\s*" + NUMBER),
    "radius": re.compile(r"(?:\bcornerRadius\s*:\s*|\.cornerRadius\s*\(\s*)" + NUMBER),
    "animation": re.compile(r"\b(?:duration|response|blendDuration)\s*:\s*" + NUMBER),
    "semantic-font": re.compile(r"\.font\(\.(?:caption2?|callout|subheadline|headline|body|title[123]?)\b"),
    "semantic-small": re.compile(r"\.system\(\s*\.caption2?\b"),
    "font-floor": re.compile(r"\.system\s*\(\s*size\s*:\s*(?:[0-9](?:\.\d+)?|10(?:\.\d+)?)(?![\d.])"),
    "status-colour": re.compile(r"(?<![\w.\\])(?:Color)?\.(?:orange|red|green)\b"),
    "spaced-percent": re.compile(r"\) %(?: left| used|/h)| %%/h"),
    "elapsed-unit": re.compile(r'\\\([^\n"]*\) (?:min|h)(?![\w=])|" (?:min|h)"|%[\d.*]*[df] (?:min|h)(?![\w=])'),
    "fixed-clock": re.compile(r'String\s*\(\s*format:\s*"(?:at |between )?%02d:%02d|dateFormat\s*=\s*"HH:mm"'),
    "missing-clock-minutes": re.compile(r'setLocalizedDateFormatFromTemplate\("EEEj"\)'),
    "currency-table": re.compile(r'\bfunc\s+currencySymbol\b|"(?:EUR|GBP)"\s*:'),
    "token-math": re.compile(r"/\s*1_000(?:_000)*(?![\d_])"),
    "monitor-wording": re.compile(r'"(?:Monitor (?:offline|disconnected|not connected)|The monitor is not (?:connected|reachable|answering|running)|core is not connected)'),
    "ui-name": re.compile(r'"[^"\n]*(?:Effect Studio|Lights Studio|One at a Time|Status Only|Global Mix|Blend mode)[^"\n]*"|"Blend"'),
    "usage-direction": re.compile(r'% left|percent[^"\n]*\) left'),
    "quota-tone": re.compile(r'JRBarTokens\.Ink\.attention'),
    "block-meter": re.compile(r"[\u2580-\u259f\u25a0\u25a1\u25b0\u25b1]+"),
}


def swift_regions(source: str) -> tuple[str, str]:
    """Mask comments for text checks, then strings for syntax checks."""
    text = list(source)
    code = list(source)
    i = 0
    while i < len(source):
        start = i
        comment = False
        if source.startswith("//", i):
            i = source.find("\n", i)
            if i < 0:
                i = len(source)
            comment = True
        elif source.startswith("/*", i):
            depth = 1
            i += 2
            while i < len(source) and depth:
                if source.startswith("/*", i):
                    depth += 1
                    i += 2
                elif source.startswith("*/", i):
                    depth -= 1
                    i += 2
                else:
                    i += 1
            comment = True
        else:
            literal = re.match(r'(\#*)("""|")', source[i:]) if source[i] in '#"' else None
            if literal:
                hashes, quote = literal.groups()
                closing = quote + hashes
                i += len(literal.group())
                while i < len(source):
                    if source.startswith("\\" + hashes, i):
                        i += 2 + len(hashes)
                    elif source.startswith(closing, i):
                        i += len(closing)
                        break
                    else:
                        i += 1
            else:
                i += 1
                continue
        for offset in range(start, min(i, len(source))):
            if source[offset] != "\n":
                code[offset] = " "
                if comment:
                    text[offset] = " "
    return "".join(text), "".join(code)


def offenders(source: str, path: str = "") -> Counter[str]:
    text, code = swift_regions(source)
    exception_lines = {
        source.count("\n", 0, match.start())
        for match in MARKER.finditer(source)
        if not text[match.start():match.end()].strip()
    }
    found: Counter[str] = Counter()
    for kind, pattern in PATTERNS.items():
        if kind in {"semantic-font", "semantic-small", "font-floor", "status-colour", "elapsed-unit"} and "/Notch/" in path:
            continue
        if kind == "status-colour" and ("/JRBarCore/" in path or "/Utilities/MenuBar/" in path):
            continue
        if kind in {"currency-table", "token-math"} and path.endswith("JRBarCore/Wording.swift"):
            continue
        if kind == "monitor-wording" and path.endswith("JRBarCore/StatusWords.swift"):
            continue
        if kind == "ui-name" and ("/Notch/" in path or "/Utilities/MenuBar/" in path or path.endswith("/WhatsNewCatalog.swift")):
            continue
        if kind == "usage-direction" and path.endswith(("/StatusIconRenderer.swift", "/StatusItemController.swift", "/ClaudeStatusLineSection.swift")):
            continue
        if kind == "quota-tone" and ("/Notch/" in path or path.endswith("JRBarUI/StatusBadge.swift")):
            continue
        text_checks = {"block-meter", "spaced-percent", "elapsed-unit", "fixed-clock", "missing-clock-minutes", "currency-table", "monitor-wording", "ui-name", "usage-direction"}
        for match in pattern.finditer(text if kind in text_checks else code):
            line = source.count("\n", 0, match.start())
            if line in exception_lines:
                continue
            snippet = " ".join(source[match.start():match.end()].split())
            found[f"{kind}: {snippet}"] += 1
    return found


def scan(root: Path) -> dict[str, dict[str, int]]:
    return {
        str(path.relative_to(root)): dict(hits)
        for path in sorted((root / "app/Sources").rglob("*.swift"))
        if (hits := offenders(path.read_text(encoding="utf-8"), str(path.relative_to(root))))
    }


def differences(current: dict, baseline: dict) -> list[str]:
    errors = []
    for path in sorted(current.keys() | baseline.keys()):
        actual = Counter(current.get(path, {}))
        allowed = Counter(baseline.get(path, {}))
        for expression, count in sorted((actual - allowed).items()):
            errors.append(f"{path}: {count} new {expression}; use JRBarTokens or a reasoned exception")
        for expression, count in sorted((allowed - actual).items()):
            errors.append(f"{path}: remove {count} retired {expression} from the baseline with --prune")
    return errors


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--prune", action="store_true", help="Remove retired offenders; never add allowances.")
    options = parser.parse_args(arguments)
    path = options.root / BASELINE
    baseline = json.loads(path.read_text(encoding="utf-8"))
    current = scan(options.root)
    if options.prune:
        pruned = {
            file: dict(Counter(hits) & Counter(current.get(file, {})))
            for file, hits in baseline.items()
            if Counter(hits) & Counter(current.get(file, {}))
        }
        path.write_text(json.dumps(pruned, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        baseline = pruned
    errors = differences(current, baseline)
    warnings = sum(swift_regions(file.read_text(encoding="utf-8"))[0].count(" — ")
                   for file in (options.root / "app/Sources").rglob("*.swift"))
    if warnings:
        print(f"Warning: {warnings} UI em dash separators remain; use a sentence or a middle dot.")
    for error in errors:
        print(error)
    count = sum(sum(hits.values()) for hits in current.values())
    print(f"Design token guard: {count} baseline offenders; {len(errors)} errors.")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
