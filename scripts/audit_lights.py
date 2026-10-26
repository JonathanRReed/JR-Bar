#!/usr/bin/env python3
"""Audit firmware programs without discovering or writing to any device.

Use the repository Python environment. --quick is a smoke matrix. The default
matrix includes all provider motions, parameter boundaries and synthetic custom
presets. --presets adds exported {name, motion, parameters} Studio presets.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(REPO / "src"), str(REPO / "tests"), str(REPO / "scripts")]

from light_audit import (  # noqa: E402
    Case,
    Firmware,
    Variant,
    baseline_delta,
    cases,
    inspect,
    settings_for,
    topologies,
)
from review_effects import write_timeline  # noqa: E402

BASELINE = REPO / "tests/fixtures/light-audit-baseline.json"
SOURCES = (
    "src/jrbar/colors.py", "src/jrbar/light_mix.py", "src/jrbar/motion_shapes.py",
    "src/jrbar/led_status.py", "src/jrbar/core_runtime.py", "src/jrbar/effect_registry.py",
    "src/jrbar/dot_role.py", "src/jrbar/linked_sync.py", "src/jrbar/core_projection.py",
    "app/Sources/JRBarLEDS/LEDSSampler.swift", "app/Sources/JRBarApp/ScreenBarController.swift",
    "app/Sources/JRBarCore/CoreMessages.swift", "app/Sources/JRBarApp/AppDelegate.swift",
    "app/Sources/JRBarApp/LEDFeed.swift", "app/Sources/JRBarApp/EffectStudioLights.swift",
    "src/jrbar/resources/sdled.wasm", "tests/light_audit.py", "scripts/audit_lights.py",
)
CAUSES = {
    "mirror_budget": ("Dot widening exceeds the Screen Bar parser budget",
        "app/Sources/JRBarLEDS/LEDSSampler.swift", "public func rawCodes(", "src/jrbar/core_runtime.py", "mirror_program = dot_mirror_program or mirror.program"),
    "mirror_pixels": ("Widening changes the Dot's interpolated travel profile",
        "app/Sources/JRBarLEDS/LEDSSampler.swift", "public func rawCodes(", "src/jrbar/core_runtime.py", "mirror_program = dot_mirror_program or mirror.program"),
    "provider_equivalence": ("Sessions change provider colours and share geometry",
        "src/jrbar/colors.py", "def _active_agents(", "src/jrbar/light_mix.py", "if len(selected) > 1 and len({agent.provider"),
    "reassert_phase": ("Reassert reparses the program without a phase rotation",
        "src/jrbar/led_status.py", "if reassert and self.last_applied_monotonic", "src/jrbar/led_wasm.py", "def parse(self,"),
    "sweep_path": ("The native or compact sweep loses its local head path",
        "src/jrbar/motion_shapes.py", "def _motion_lines(", "src/jrbar/light_mix.py", "def _body("),
    "share_fidelity": ("Share composition changes the native local timeline",
        "src/jrbar/light_mix.py", "def _shares(", "src/jrbar/light_mix.py", "def _keyframe_shares("),
    "temporal_period": ("Combined tracks change a provider's native period",
        "src/jrbar/light_mix.py", "def _shares(", "src/jrbar/light_mix.py", "def _keyframe_shares("),
    "temporal_range": ("Combined tracks change the temporal floor or ceiling",
        "src/jrbar/light_mix.py", "def _shares(", "src/jrbar/motion_shapes.py", "def _motion_lines("),
    "dark_share": ("A share adds darkness beyond the native motion's allowance",
        "src/jrbar/light_mix.py", "def _shares(", "src/jrbar/motion_shapes.py", "def _motion_lines("),
    "loop_seam": ("A repeating program has a channel discontinuity at its seam",
        "src/jrbar/motion_shapes.py", "def _motion_lines(", "src/jrbar/light_mix.py", "def _cycle("),
    "legacy_solo": ("Solo bytes differ from 740c1b92",
        "src/jrbar/colors.py", "def _single_agent_program(", "src/jrbar/motion_shapes.py", "def render_motion("),
}

_WORKER_FIRMWARE = None


def inspect_batch(batch):
    global _WORKER_FIRMWARE
    if _WORKER_FIRMWARE is None:
        _WORKER_FIRMWARE = Firmware()
    return [inspect(case, _WORKER_FIRMWARE) for case in batch]


def source_location(path, needle):
    return f"{path}:{next(i for i, line in enumerate((REPO / path).read_text().splitlines(), 1) if needle in line)}"


def provenance():
    return {
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip(),
        "status": subprocess.check_output(["git", "status", "--short"], cwd=REPO, text=True).splitlines(),
        "sha256": {path: hashlib.sha256((REPO / path).read_bytes()).hexdigest() for path in SOURCES},
    }


def historical_solo(results, firmware):
    """Render the historical package in a separate interpreter and temp tree."""
    selected = [r for r in results if r.case.counts == (1,) and r.case.mix not in {"classic", "color_blend"}
                and r.case.variant.name.endswith(".default")]
    requests = [{"key": r.case.key, "settings": settings_for(r.case.variant, r.case.mix).to_dict(),
                 "leds": r.case.leds, "state": r.case.state} for r in selected]
    code = """
import json, sys
from datetime import datetime, timezone
from jrbar.colors import ColorSettings, program_for_snapshot
from jrbar.models import AgentMode, AgentStatus
modes = dict(working=AgentMode.WORKING, stale=AgentMode.WORKING,
    ask=AgentMode.WAITING_FOR_INPUT, done=AgentMode.COMPLETED,
    idle=AgentMode.IDLE_READY, failed=AgentMode.BLOCKED_ERROR)
output = {}
for row in json.load(sys.stdin):
    agent = AgentStatus(provider='codex', agent_id='synthetic:codex:0', display_name='codex',
        mode=modes[row['state']], updated_at=datetime(2026,10,1,tzinfo=timezone.utc),
        stale=row['state']=='stale', event_name='PermissionRequest' if row['state']=='ask' else 'test')
    try:
        output[row['key']] = program_for_snapshot((agent,), colors=ColorSettings.from_dict(row['settings']),
            led_count=row['leds'])[1]
    except Exception as error:
        output[row['key']] = {'error': str(error)}
json.dump(output, sys.stdout)
"""
    archive = subprocess.check_output(["git", "archive", "740c1b92", "src"], cwd=REPO)
    with tempfile.TemporaryDirectory(prefix="jrbar-light-history-") as directory:
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(directory, filter="data")
        env = dict(os.environ, PYTHONPATH=str(Path(directory) / "src"))
        process = subprocess.run([sys.executable, "-c", code], input=json.dumps(requests),
                                 text=True, capture_output=True, env=env, cwd=directory, check=True)
    historical = json.loads(process.stdout)
    for result in selected:
        expected = historical[result.case.key]
        result.checks.add("legacy_solo")
        if expected != result.program:
            if isinstance(expected, dict):
                result.failures["legacy_solo"] = f"historical render failed: {expected}"
            else:
                result.failures["legacy_solo"] = "solo bytes changed from 740c1b92"
                # Keep pixel equality separate from byte identity.
                before = firmware.trace(expected, result.case.leds)
                after = firmware.trace(result.program, result.case.leds)
                result.failures["legacy_solo"] += f"; period {before.period} -> {after.period}ms"
    return len(selected)


def write_report(out, results, firmware, receipt, legacy_count, integration):
    failed = defaultdict(list)
    checks = Counter()
    families = defaultdict(Counter)
    representatives = {}
    for result in results:
        checks.update(result.checks)
        for code in result.failures:
            failed[code].append(result.case.key)
            families[result.case.variant.motion][code] += 1
            previous = representatives.get(code)
            # Prefer two distinct providers and a working eight-LED default.
            score = (result.case.state == "working", result.case.leds == 8,
                     result.case.variant.name.endswith(".default"), result.case.counts == (1, 1))
            if previous is None or score > previous[0]:
                representatives[code] = (score, result)
    images = {}
    for code, (_score, result) in representatives.items():
        try:
            trace = firmware.trace(result.program, result.case.leds)
        except ValueError:
            continue
        path = out / f"{code}.png"
        frames = trace.frames
        if code == "reassert_phase":
            reference, replay = firmware.reassert_frames(result.program, result.case.leds)
            frames = tuple((*left, (30, 30, 30), *right) for left, right in zip(reference, replay))
        elif code == "provider_equivalence":
            from light_audit import statuses

            from jrbar.colors import program_for_snapshot
            solo = program_for_snapshot(statuses((1,), result.case.state), led_count=result.case.leds,
                colors=settings_for(result.case.variant, result.case.mix))[1]
            reference = firmware.trace(solo, result.case.leds).frames
            frames = tuple((*left, (30, 30, 30), *right) for left, right in zip(reference, frames))
        frames = frames[::max(1, len(frames) // 600)]
        write_timeline(path, frames, cell_width=30, cell_height=1)
        images[code] = path.name
    ranked = []
    for code in sorted(failed, key=lambda key: (-len(failed[key]), key)):
        row = {"invariant": code, "count": len(failed[code]), "checked": checks[code],
               "representative": representatives[code][1].case.key,
               "detail": representatives[code][1].failures[code], "image": images.get(code)}
        if code in CAUSES:
            title, p1, n1, p2, n2 = CAUSES[code]
            row.update(cause=title, locations=[source_location(p1, n1), source_location(p2, n2)])
        ranked.append(row)
    document = {"schema": 1, "provenance": receipt, "cases": len(results),
                "failed_cases": sum(bool(r.failures) for r in results), "checks": dict(checks),
                "historical_solo_cases": legacy_count, "integration": integration,
                "reassert_actions": dict(Counter(r.reassert_action for r in results if r.reassert_action)),
                "families": {key: dict(value) for key, value in sorted(families.items())},
                "ranked": ranked, "failures": dict(failed),
                "examples": {code: {"program": result.program, "played": result.played,
                                    "warnings": result.warnings, "detail": result.failures[code]}
                             for code, (_score, result) in representatives.items()}}
    (out / "report.json").write_text(json.dumps(document, indent=2) + "\n")
    lines = ["# Lights invariant audit", "", f"Revision `{receipt['head']}`. Firmware only. No device I/O.", "",
             f"{len(results):,} cases; {document['failed_cases']:,} cases fail at least one invariant.", "",
             "Counts overlap when one case breaks several invariants. Source hashes are in report.json.", "",
             "| Invariant | Failing / checked | Source |", "|---|---:|---|"]
    for row in ranked:
        lines.append(f"| {row['invariant']} | {row['count']:,} / {row['checked']:,} | "
                     + ", ".join(row.get("locations", [])) + " |")
    lines.extend(["", "## Failing animation families", "", "| Animation | Failures by invariant |", "|---|---|"])
    for family, counts in sorted(families.items()):
        lines.append(f"| {family} | " + ", ".join(f"{code}={count}" for code, count in sorted(counts.items())) + " |")
    for row in ranked:
        lines.extend(["", f"## {row.get('cause', row['invariant'])}", "",
                      f"`{row['representative']}`. {row['detail']}.", ""])
        if row["image"]:
            lines.append(f"![{row['invariant']}]({row['image']})")
    lines.extend(["", "## Scope and thresholds", "",
        "Every motion in PROVIDER_ANIMATION_EFFECTS, including Automatic. Default, joint low and high Studio values. "
        "Three synthetic saved presets and six chosen-sweep/Automatic-follower variants. "
        "Every partition of 1 to 6 sessions across 1 to 3 providers. Provider-name permutations are excluded. "
        "Every mix, both shipping LED counts and six states. Stale means AgentStatus.stale=True with a working mode.", "",
        "Each distinct program runs from zero for three complete encoded loops at 1 to 16 ms ticks. "
        "The first pass warms the engine; checks inspect the following passes. "
        "Sweep heads must visit adjacent local positions and return for bouncing motions. "
        "Uniform glow, multi-head profiles and one-LED shares have no unique head and skip that check. "
        "One-way paths may wrap. Darkness means below 5% of the observed peak for more than one third of a loop. "
        "Temporal periods allow 4 ms rounding; ranges and native share comparisons allow 24/255 per channel. "
        "A solo program defines its own native dark gaps, including its settle. "
        "Ask priority requires an ask plan and a full ask crest under competing states; ambient shares may remain visible. "
        "Seams allow 41/255 across two ticks; intentional Blink steps are exempt. "
        "Reassert reparses at 37% of the second cycle and compares the next cycle to uninterrupted firmware output. "
        "Timeline rows run downward in time; columns are LEDs. A grey divider separates "
        "the uninterrupted and reasserted timelines, or the one-session and repeated-session timelines.", "",
        "Share fidelity applies to retained provider motion, not mixes that intentionally replace it. "
        "Native reference tracks use the same motion renderer. On 1/3/4-LED shares, the existing local roll mapper "
        "expands the track for the eight-LED emulator. The independent head-path check covers skipped mapping positions. "
        "This is composition evidence, not an independent visual definition of every animation. "
        "The historical comparison covers default solo motions in the seven motion-preserving mixes. "
        "Custom exported presets can be supplied with --presets; installed personal presets are not read.", "",
        f"Mirror/cue/controller integration: {integration}.", "",
        "The Screen Bar check exercises daemon mirror publication and nominal emulator pixels. "
        "Swift display rendering, calibration, real firmware scheduling, device writes and hardware are not tested.", ""])
    (out / "report.md").write_text("\n".join(lines))
    return document


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--record-baseline", action="store_true")
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--presets", type=Path)
    parser.add_argument("--skip-integration", action="store_true")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    receipt = provenance()
    firmware = Firmware()
    matrix = list(cases(quick=args.quick))
    if args.presets:
        from light_audit import STATES

        from jrbar.light_mix import MIX_LABELS
        for row in json.loads(args.presets.read_text()):
            variant = Variant("imported." + row["name"], row["motion"], json.dumps(row["parameters"]))
            matrix.extend(Case(variant, mix, counts, leds, state)
                          for mix in MIX_LABELS for counts in topologies() for leds in (8, 2) for state in STATES)
    results = []
    batches = defaultdict(list)
    for case in matrix:
        batches[case.variant.name].append(case)
    with ProcessPoolExecutor(max_workers=max(1, args.jobs), max_tasks_per_child=1) as pool:
        for batch_results in pool.map(inspect_batch, batches.values()):
            results.extend(batch_results)
            print(f"{len(results)}/{len(matrix)} cases", flush=True)
    legacy_count = historical_solo(results, firmware)
    bank = {(r.case.leds, r.program): r.case.key for r in results if r.program and "exception" not in r.failures}
    bank_path = args.out.resolve() / "programs.json"
    bank_path.write_text(json.dumps([{"leds": count, "program": program, "case": key}
                                    for (count, program), key in bank.items()]))
    # The Screen Bar receives the write gate's result, not the pre-write
    # plans in programs.json. Keep a corpus for the Swift sampler check.
    from jrbar.presentation_compiler import compile_presentation_program

    delivered = []
    for row in json.loads(bank_path.read_text()):
        compiled = compile_presentation_program(row["program"], led_count=row["leds"])
        if not compiled.accepted:
            raise RuntimeError("The hardware write gate refused an audited program")
        delivered.append(dict(row, program=compiled.program))
    (args.out / "delivered-programs.json").write_text(json.dumps(delivered))
    integration = "Not run (--skip-integration)"
    if not args.skip_integration:
        process = subprocess.run([sys.executable, "-m", "pytest", "tests/test_light_audit.py",
            "-q", "-k", "mirror or cue or controller_reassert"], cwd=REPO, text=True, capture_output=True,
            env=dict(os.environ, JRBAR_AUDIT_PROGRAMS=str(bank_path)))
        (args.out / "integration.txt").write_text(process.stdout + process.stderr)
        integration = f"{'Verified' if process.returncode == 0 else 'Failed'}; see integration.txt"
    if provenance()["sha256"] != receipt["sha256"]:
        raise RuntimeError("Source changed during audit; rerun to bind the report to one source snapshot")
    document = write_report(args.out, results, firmware, receipt, legacy_count, integration)
    expected = json.loads(args.baseline.read_text())["failures"] if args.baseline.exists() else {}
    if args.quick or args.presets:
        keys = {case.key for case in matrix}
        expected = {code: [key for key in values if key in keys] for code, values in expected.items()}
    new, resolved = baseline_delta(document["failures"], expected)
    (args.out / "baseline-delta.json").write_text(json.dumps({"new": new, "resolved": resolved}, indent=2) + "\n")
    if args.record_baseline:
        if args.quick or args.presets:
            parser.error("Record the baseline only from the full standard matrix")
        if new and args.baseline.exists():
            parser.error("Refusing to record a baseline with new failures; inspect baseline-delta.json")
        args.baseline.write_text(json.dumps({"schema": 1, "head": receipt["head"],
            "cases": len(results), "failures": document["failures"]}, indent=2) + "\n")
    print(json.dumps({"cases": len(results), "failed_cases": document["failed_cases"],
                      "new": sum(map(len, new.values())), "resolved": sum(map(len, resolved.values())),
                      "report": str(args.out / "report.md")}))
    return int((bool(new) and not args.record_baseline) or integration.startswith("Failed"))


if __name__ == "__main__":
    raise SystemExit(main())
