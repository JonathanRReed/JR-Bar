#!/usr/bin/env python3
"""Export every motion as the daemon draws it, for the Swift render proofs.

Writes ``app/Tests/JRBarLEDSTests/Fixtures/programs/motions/*.json``: one
file per motion x {8, 2} LEDs x {default, min, max} values, each the exact
program ``render_effect`` sends (the renderer the live Pro, the Settings
thumbnails and Effect Studio share) plus the firmware's own colours at the
sampler's reference times. The Swift side draws them
(``LEDMotionRenderProofTests``) and checks its sampler against these
samples, so the pictures are the daemon's bytes and the two engines stay
honest. The Iris lid looks and the Land and Ripple finishes ride along.

Run it with the repo venv after changing a motion:

    .venv/bin/python scripts/export_motion_fixtures.py
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
if str(REPO / "src") not in sys.path:
    sys.path.insert(0, str(REPO / "src"))

from jrbar import celebrations, core_effects, lid_presets  # noqa: E402
from jrbar._led_wasm_legacy import SdLedWasmController  # noqa: E402
from jrbar.effect_registry import PROVIDER_ANIMATION_EFFECTS  # noqa: E402

DEFAULT_OUT = REPO / "app" / "Tests" / "JRBarLEDSTests" / "Fixtures" / "programs" / "motions"
#: The times ``SamplerParityTests`` requires of every program fixture.
SAMPLE_TIMES_MS: tuple[int, ...] = (0, 50, 100, 250, 500, 1000, 1500, 2000, 3700)
ENGINE = "sdled.wasm via jrbar._led_wasm_legacy.SdLedWasmController: reset(0); parse(program, 0); step(t_ms)"
PALETTE = ("#FF2D55", "#5AC8FA", "#FFCC00", "#34C759")


def _end_value(parameter, *, high: bool):
    if parameter.value_type in ("number", "integer"):
        return parameter.maximum if high else parameter.minimum
    if parameter.value_type == "choice":
        return parameter.choices[-1] if high else parameter.choices[0]
    if parameter.value_type == "boolean":
        return high
    if parameter.value_type == "palette":
        return list(PALETTE[: parameter.maximum_items]) if high else []
    return parameter.default


def _samples(program: str, led_count: int) -> list[dict]:
    controller = SdLedWasmController(led_count)
    controller.reset(0)
    result = controller.parse(program, 0)
    if not result.ok:
        raise SystemExit(f"firmware rejected {program!r}: {result.error_name}")
    return [
        {"t_ms": t_ms, "colors": [list(pixel) for pixel in controller.step(t_ms)]}
        for t_ms in SAMPLE_TIMES_MS
    ]


def fixtures() -> list[dict]:
    rows: list[dict] = []
    for effect in PROVIDER_ANIMATION_EFFECTS:
        if effect.identifier == "auto":
            continue
        variants = {
            "default": {},
            "min": {p.name: _end_value(p, high=False) for p in effect.parameter_metadata},
            "max": {p.name: _end_value(p, high=True) for p in effect.parameter_metadata},
        }
        for variant, values in variants.items():
            parameters = core_effects.normalize_parameters(effect, values)
            for led_count in (8, 2):
                program = core_effects.render_effect(effect, parameters, led_count=led_count)
                rows.append(
                    {
                        "name": f"{effect.identifier}_{variant}_{led_count}led",
                        "motion": effect.identifier,
                        "variant": variant,
                        "led_count": led_count,
                        "program": program,
                    }
                )
    for shape in lid_presets.LID_SHAPES:
        for led_count in (8, 2):
            # Drawn as the Moments thumbnails draw them: a close starts lit.
            program = lid_presets.render_lid_shape(
                shape, led_count=led_count, accent="#D97757", preview=True
            )
            rows.append(
                {
                    "name": f"lid_{shape}_{led_count}led",
                    "motion": f"lid_{shape}",
                    "variant": "default",
                    "led_count": led_count,
                    "program": program,
                }
            )
    for style in (celebrations.DONE_CELEBRATION_LAND, celebrations.DONE_CELEBRATION_RIPPLE):
        for led_count in (8, 2):
            program = celebrations.done_celebration_program(style, "#00FF66", led_count=led_count)
            rows.append(
                {
                    "name": f"finish_{style}_{led_count}led",
                    "motion": f"finish_{style}",
                    "variant": "default",
                    "led_count": led_count,
                    "program": program,
                }
            )
    for row in rows:
        row["engine"] = ENGINE
        row["samples"] = _samples(row["program"], row["led_count"])
    return rows


#: The Swift effect-model tests' catalog: the real ``list_effects`` document
#: with the mock's Night Lab pack installed, so pack decoding stays covered.
CATALOG_FIXTURE = REPO / "app" / "Tests" / "JRBarCoreTests" / "Fixtures" / "list_effects.json"
NIGHT_LAB_PACK = {
    "id": "nightlab",
    "name": "Night Lab",
    "version": 2,
    "safety": {"data_only": True, "network": False},
    "accessibility": {"reduced_motion": True, "high_contrast": True},
    "license": {"spdx_id": "CC0-1.0", "label": "Creative Commons Zero", "source_url": "https://example.org/nightlab"},
    "effects": [
        {"id": "ember", "label": "Ember", "description": "A low warm shimmer for late sessions.", "meaning": "quiet presence",
         "surfaces": ["screen_bar", "sidepulse_pro", "settings_preview"], "safety": "safe", "energy": "low",
         "reduce_motion_fallback": "coal", "motion": "flicker", "color": "#FF7A1A", "duration_seconds": 3.0, "luminance_floor": 0.25},
        {"id": "coal", "label": "Coal", "description": "The ember at rest.", "meaning": "quiet presence",
         "surfaces": ["screen_bar", "sidepulse_pro", "sidepulse_dot", "settings_preview"], "safety": "safe", "energy": "low",
         "motion": "steady", "color": "#8A2E00", "luminance": 0.6},
        {"id": "lighthouse", "label": "Lighthouse", "description": "A slow beam that sweeps past every few seconds.", "meaning": "periodic activity",
         "surfaces": ["screen_bar", "sidepulse_pro", "settings_preview"], "safety": "safe", "energy": "medium",
         "reduce_motion_fallback": "coal", "motion": "scanner", "color": "#FFE9B0", "duration_seconds": 4.0, "beam_width": 2},
        {"id": "beacon", "label": "Beacon", "description": "A hard red beacon for things that cannot wait.", "meaning": "critical alert",
         "surfaces": ["screen_bar", "sidepulse_pro", "sidepulse_dot", "settings_preview"], "safety": "critical", "energy": "high",
         "reduce_motion_fallback": "coal", "motion": "blink", "color": "#FF2D1A", "cadence": "deliberate"},
    ],
}


def write_catalog_fixture(target: Path = CATALOG_FIXTURE) -> None:
    from jrbar.effect_packs import validate_pack

    pack = validate_pack(NIGHT_LAB_PACK)
    registry = core_effects.registry_with_packs((pack,))
    document = core_effects.catalog_document(registry, (pack,))
    target.write_text(json.dumps(document, indent=1) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument(
        "--no-catalog", action="store_true", help="leave the Swift list_effects.json fixture alone"
    )
    arguments = parser.parse_args()
    if not arguments.no_catalog:
        write_catalog_fixture()
        print(f"wrote {CATALOG_FIXTURE}")
    out: Path = arguments.out
    out.mkdir(parents=True, exist_ok=True)
    written = set()
    for row in fixtures():
        target = out / f"{row['name']}.json"
        target.write_text(json.dumps(row, separators=(",", ":")) + "\n")
        written.add(target.name)
    for stale in out.glob("*.json"):
        if stale.name not in written:
            stale.unlink()
    print(f"wrote {len(written)} motion fixtures to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
