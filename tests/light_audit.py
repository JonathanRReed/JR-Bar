"""Firmware measurements for the catalogue and mixed-provider audit.

This module never constructs a device writer. All pixels come from sdled.wasm.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from functools import lru_cache
from itertools import pairwise, product

from jrbar.animation import (
    IndexedPaint,
    PaintStep,
    read_program,
    render_step,
    step_duration_ms,
)
from jrbar.colors import ColorSettings, _active_agents, program_for_snapshot
from jrbar.effect_registry import PROVIDER_ANIMATION_EFFECTS
from jrbar.led_status import LedDisplayState
from jrbar.led_wasm import RawSdLedWasmController
from jrbar.light_mix import (
    MIX_LABELS,
    _body,
    _share_steps,
    explain_what_plays,
    mix_catalog,
    selected_agents,
)
from jrbar.linked_sync import (
    DeviceTiming,
    PhaseRotationUnavailable,
    apply_device_timing,
    playback_loop_ms,
    playback_span_ms,
)
from jrbar.models import AgentMode, AgentStatus

PROVIDERS = ("codex", "claude", "devin")
STATES = {
    "working": AgentMode.WORKING,
    "ask": AgentMode.WAITING_FOR_INPUT,
    "done": AgentMode.COMPLETED,
    "idle": AgentMode.IDLE_READY,
    "failed": AgentMode.BLOCKED_ERROR,
    "stale": AgentMode.WORKING,
}
BOUNCE = {"kitt", "scanner", "pendulum"}
TRAVEL = BOUNCE | {"chase", "comet", "marquee", "glint", "tide"}
TEMPORAL = {"breathe", "heartbeat", "blink", "duotone"}
ERROR_CODES = {"budget", "geometry", "firmware", "exception", "explanation"}
CHANNEL_TOLERANCE = 24
SEAM_TOLERANCE = 41  # 16% of an 8-bit channel across two 16ms frames.
DARK_FRACTION = 1 / 3
NOW = datetime(2026, 10, 1, tzinfo=timezone.utc)


@dataclass(frozen=True)
class Variant:
    name: str
    motion: str
    parameters_json: str = "{}"
    automatic_followers: bool = False

    @property
    def parameters(self):
        return json.loads(self.parameters_json)


def catalogue():
    """Defaults, joint slider extremes, and synthetic saved Studio presets."""
    result = []
    for effect in PROVIDER_ANIMATION_EFFECTS:
        for profile in ("default", "low", "high"):
            values = {}
            if profile != "default":
                for spec in effect.parameter_metadata:
                    bound = spec.minimum if profile == "low" else spec.maximum
                    if bound is not None:
                        values[spec.name] = bound
                    elif spec.choices:
                        values[spec.name] = spec.choices[0 if profile == "low" else -1]
            result.append(Variant(f"{effect.identifier}.{profile}", effect.identifier, json.dumps(values)))
    for motion in ("kitt", "scanner", "pendulum"):
        for glow in (0, 20):
            result.append(Variant(f"{motion}.follow-glow{glow}", motion,
                json.dumps({"duration_seconds": 2.2, "background_glow": glow}), True))
    result.extend((
        Variant("custom.palette", "duotone", json.dumps({"duration_seconds": 3.7,
            "palette": ["#00CCFF", "#FF8800"]})),
        Variant("custom.reverse", "chase", json.dumps({"duration_seconds": 3.7,
            "direction": "reverse", "crests": 1, "softness": 0.35})),
        Variant("custom.heartbeat", "heartbeat", json.dumps({"duration_seconds": 3.7, "rest_ratio": 0.45})),
    ))
    return tuple(result)


def topologies():
    # Every integer partition of 1..6 sessions over 1..3 named providers.
    # Permuting the same counts across provider names is outside this matrix.
    return tuple(counts for total in range(1, 7) for providers in range(1, min(3, total) + 1)
                 for counts in product(range(1, total + 1), repeat=providers)
                 if sum(counts) == total and tuple(sorted(counts, reverse=True)) == counts)


@dataclass(frozen=True)
class Case:
    variant: Variant
    mix: str
    counts: tuple[int, ...]
    leds: int
    state: str

    @property
    def key(self):
        return "/".join((self.variant.name, self.mix, "+".join(map(str, self.counts)),
                         str(self.leds), self.state))


def cases(*, quick=False):
    variants = catalogue()
    counts = topologies()
    states = tuple(STATES)
    if quick:
        variants = tuple(v for v in variants if v.name in {
            "kitt.default", "breathe.default", "heartbeat.default", "scanner.default",
            "pendulum.default", "chase.default", "kitt.follow-glow0", "custom.palette"})
        counts = ((1,), (2,), (1, 1), (2, 1), (2, 2, 1))
        states = ("working", "ask", "failed", "stale")
    for variant, mix, topology, leds, state in product(variants, MIX_LABELS, counts, (8, 2), states):
        yield Case(variant, mix, topology, leds, state)


@lru_cache(maxsize=512)
def settings_for(variant, mix):
    animations = {provider: variant.motion if index == 0 or not variant.automatic_followers else "auto"
                  for index, provider in enumerate(PROVIDERS)}
    # Use the real schema boundaries for the mix knobs as well as the motion.
    boundary = "minimum" if variant.name.endswith(".low") else "maximum"
    mix_values = {}
    if variant.name.endswith((".low", ".high")):
        mix_values = {row["id"]: {p["key"]: p[boundary] for p in row["parameters"]}
                      for row in mix_catalog()}
    return ColorSettings.from_dict({
        "mix_schema_version": 1, "blend_mode": mix, "cycle_speed_seconds": 2.2,
        "provider_animation": animations,
        "provider_animation_parameters": {p: variant.parameters for p, motion in animations.items()
                                           if motion != "auto"},
        "mix_effect": {"effect_id": "marquee", "parameters": {}},
        "mix_parameters": mix_values, "mode_animation": {"working": "roll"},
        "fade_floor": {"working": 0.01}, "fade_ceiling": {"working": 0.5},
    })


@lru_cache(maxsize=256)
def statuses(counts, state):
    return tuple(AgentStatus(provider=provider, agent_id=f"synthetic:{provider}:{session}",
        display_name=provider, mode=STATES[state], stale=state == "stale", updated_at=NOW,
        event_name="PermissionRequest" if state == "ask" else "test")
        for provider, count in zip(PROVIDERS, counts) for session in range(count))


@dataclass(frozen=True)
class Trace:
    period: int
    interval: int
    frames: tuple
    looping: bool

    def cycle(self, number=1):
        return self.frames[number * self.period // self.interval:(number + 1) * self.period // self.interval]


class Firmware:
    def __init__(self):
        self.controllers = {n: RawSdLedWasmController(n) for n in (2, 8)}

    @lru_cache(maxsize=128)
    def trace(self, program, count):
        animation, problems = read_program(program, led_count=count)
        errors = [p.code for p in problems if p.severity == "error"]
        if errors:
            raise ValueError(",".join(errors))
        loop = playback_loop_ms(animation)
        period = max(16, loop or sum(playback_span_ms(step) for step in animation.steps))
        # Never skip engine ticks. Start at zero and warm an entire pass.
        interval = max(1, min(16, period // 256))
        controller = self.controllers[count]
        controller.reset(0)
        parsed = controller.parse(program, 0)
        if not parsed.ok:
            raise ValueError(f"{parsed.error_name} at {parsed.line}:{parsed.column}")
        frames = controller.step_batch(0, interval, (3 * period) // interval + 2)
        return Trace(period, interval, tuple(tuple(frame) for frame in frames), loop is not None)

    @lru_cache(maxsize=512)
    def reassert_plan(self, program, count):
        trace = self.trace(program, count)
        when = int(trace.period * 1.37) // trace.interval * trace.interval
        try:
            return apply_device_timing(program, DeviceTiming(anchor=0, preserve_phase=True),
                                       led_count=count, now=when / 1000, latency_ms=0)
        except PhaseRotationUnavailable:
            return None

    def reassert_frames(self, program, count):
        trace = self.trace(program, count)
        if not trace.looping:
            return (), ()
        offset = int(trace.period * 1.37) // trace.interval
        reference = trace.frames[offset:offset + trace.period // trace.interval]
        controller = self.controllers[count]
        controller.reset(0)
        assert controller.parse(program, 0).ok
        controller.step_batch(0, trace.interval, offset)
        when = offset * trace.interval
        prepared = self.reassert_plan(program, count)
        if prepared is not None:
            assert controller.parse(prepared.program, when).ok
        replay = controller.step_batch(when, trace.interval, len(reference))
        return reference, tuple(tuple(frame) for frame in replay)

    @lru_cache(maxsize=512)
    def reassert_error(self, program, count):
        return frame_error(*self.reassert_frames(program, count))

    @lru_cache(maxsize=1024)
    def seam_error(self, program, count):
        trace = self.trace(program, count)
        return max(frame_error(trace.frames[t - 1:t], trace.frames[t + 1:t + 2])
                   for t in (trace.period // trace.interval, 2 * trace.period // trace.interval))

    @lru_cache(maxsize=1024)
    def equivalent(self, left, right, count):
        a, b = self.trace(left, count), self.trace(right, count)
        return a.period == b.period and frame_error(a.frames, b.frames) <= 1


def frame_error(left, right):
    return max((abs(a - b) for lf, rf in zip(left, right) for lp, rp in zip(lf, rf)
                for a, b in zip(lp, rp)), default=0)


def head_path(frames, slots):
    positions = []
    for frame in frames:
        levels = [sum(frame[index]) for index in slots]
        peak = max(levels)
        # A uniform bed, including 100% background glow, has no visible head.
        if peak <= 2 or peak - min(levels) <= 2:
            continue
        position = levels.index(peak)
        if not positions or position != positions[-1]:
            positions.append(position)
    return positions


def sweep_errors(frames, slots, motion):
    positions = head_path(frames, slots)
    if len(slots) < 2:
        return []
    if not positions:
        return ["no visible head"]
    errors = []
    if set(positions) != set(range(len(slots))):
        errors.append(f"visited {sorted(set(positions))} of {list(range(len(slots)))}")
    for a, b in pairwise(positions):
        allowed = abs(a - b) == 1 or (motion not in BOUNCE and {a, b} == {0, len(slots) - 1})
        if not allowed:
            errors.append(f"head jumped {a} to {b}")
            break
    if motion in BOUNCE and not (any(a < b for a, b in pairwise(positions))
                                 and any(a > b for a, b in pairwise(positions))):
        errors.append("no return pass")
    return errors


def dark_fraction(frames, slots):
    levels = [max(max(frame[i]) for i in slots) for frame in frames]
    threshold = max(levels, default=0) * 0.05
    # Include a dark interval crossing the loop seam.
    longest = run = 0
    for level in levels * 2:
        run = run + 1 if level <= threshold else 0
        longest = max(longest, run)
    return min(len(levels), longest) / max(1, len(levels))


@dataclass
class Result:
    case: Case
    program: str
    played: str
    warnings: tuple
    failures: dict
    checks: set
    reassert_action: str | None = None


def inspect(case, firmware):
    settings = settings_for(case.variant, case.mix)
    rows = statuses(case.counts, case.state)
    failures = {}
    checks = set()
    reassert_action = None
    program = ""
    played = "error"
    warnings = ()

    def check(code, condition, detail):
        checks.add(code)
        if not condition:
            failures[code] = detail

    try:
        state, program = program_for_snapshot(rows, colors=settings, led_count=case.leds)
        explanation = explain_what_plays(rows, settings, led_count=case.leds)
        played, warnings = explanation["played"], tuple(explanation["warnings"])
        check("explanation", explanation["program"] == program, "what_plays and hardware bytes disagree")
        check("budget", len(program.encode()) + 15 <= 512 and len(program.splitlines()) + 1 <= 20,
              f"{len(program.encode())} bytes, {len(program.splitlines())} lines before brightness reserve")
        animation, problems = read_program(program, led_count=case.leds)
        indices = [i for step in animation.steps if isinstance(step, PaintStep)
                   for segment in step.segments if isinstance(segment, IndexedPaint) for i, _ in segment.assignments]
        check("geometry", all(0 <= i < case.leds for i in indices), f"indices {indices}")
        trace = firmware.trace(program, case.leds)
        check("firmware", True, "")
        # Pixel parity requires the Swift sampler, run on the delivered corpus
        # by the CLI and test_swift_mirror_matches_firmware. This matrix makes
        # no mirror-pixel claim from Python firmware samples alone.
        if case.state == "ask":
            challengers = tuple(replace(statuses((1,), mode)[0], agent_id=f"synthetic:challenger:{mode}")
                                for mode in ("working", "failed", "done", "idle"))
            mixed_state, mixed = program_for_snapshot(rows + challengers, colors=settings, led_count=case.leds)
            mixed_plan = explain_what_plays(rows + challengers, settings, led_count=case.leds)
            color = settings.mode_color("ask")
            ask_peak = tuple(int(color[i:i + 2], 16) for i in (1, 3, 5))
            held = firmware.trace(mixed, case.leds).frames[-1]
            check("ask_priority", state is LedDisplayState.ASK and mixed_state is LedDisplayState.ASK
                  and mixed_plan["played"] == "ask" and ask_peak in held,
                  "a competing working, failed, done or idle session displaced the ask crest")
        if any(count > 1 for count in case.counts):
            _state, solo = program_for_snapshot(statuses((1,) * len(case.counts), case.state),
                                               colors=settings, led_count=case.leds)
            check("provider_equivalence", firmware.equivalent(program, solo, case.leds),
                  f"session counts {case.counts} change the provider-only program")
        if trace.looping:
            reassert_action = "rotated" if firmware.reassert_plan(program, case.leds) else "deferred"
            seam = firmware.seam_error(program, case.leds)
            check("loop_seam", case.variant.motion == "blink" or seam <= SEAM_TOLERANCE,
                  f"boundary channel jump {seam}/255 over {2 * trace.interval}ms")
            check("reassert_phase", firmware.reassert_error(program, case.leds) <= CHANNEL_TOLERANCE,
                  "reparse at 37% of the second pass changes the following cycle by more than 24/255")

        if case.state not in {"working", "stale"} or case.mix in {"classic", "color_blend"}:
            return Result(case, program, played, warnings, failures, checks, reassert_action)
        agents = selected_agents(_active_agents(rows, settings, case.leds), settings)
        # The planner collapses one-provider sessions after selected_agents.
        if len({a.provider for a in agents}) == 1:
            agents = agents[:1]
        shares = []
        if len(agents) == 1:
            shares = [(agents[0], tuple(range(case.leds)))]
        elif played in {"round_robin", "spatial_split"}:
            priority = sorted(range(len(agents)), key=lambda index: (
                agents[index].started_at if agents[index].started_at is not None else float("inf"),
                agents[index].identity, index))
            sizes = [case.leds // len(agents)] * len(agents)
            for index in priority[:case.leds % len(agents)]:
                sizes[index] += 1
            start = 0
            for index, agent in enumerate(agents):
                size = sizes[index]
                contiguous = played == "spatial_split" or any(
                    settings.agent_animation(a.provider) in BOUNCE for a in agents)
                slots = (tuple(range(start, start + size)) if contiguous
                         else tuple(range(index, case.leds, len(agents))))
                shares.append((agent, slots))
                start += size
        explicit = [a for a in agents if settings.agent_animation(a.provider) not in {"auto", "steady"}]
        leader = explicit[0] if explicit else None
        for agent, slots in shares:
            motion = settings.agent_animation(agent.provider)
            reference_settings = settings
            if (motion == "auto" and len(agents) > 1 and leader is not None
                    and settings.agent_animation(leader.provider) in BOUNCE
                    and settings.animation_style("working") == "roll"):
                motion = settings.agent_animation(leader.provider)
                reference_settings = settings.with_agent_animation(agent.provider, motion)
                reference_settings = reference_settings.with_agent_animation_parameters(
                    agent.provider, settings.agent_animation_parameters(leader.provider))
            if not slots:
                continue
            local = tuple(tuple(frame[i] for i in slots) for frame in trace.cycle())
            # A reference uses the native local renderer, never the combined
            # mapper or its four-keyframe sampler. This detects composition loss.
            try:
                native_lines = _body(agent, reference_settings, len(slots), compact=len(agents) > 1)
                if reference_settings is not settings:
                    # Automatic fits its complete local path to the leader's
                    # step clock, including when their shares differ in size.
                    leader_slots = next(s for a, s in shares if a is leader)
                    leader_lines = _body(leader, settings, len(leader_slots), compact=True)
                    leader_animation, _ = read_program("\n".join(leader_lines), led_count=len(leader_slots))
                    local_animation, _ = read_program("\n".join(native_lines), led_count=len(slots))
                    if len(leader_animation.steps) != len(local_animation.steps):
                        raise ValueError("Automatic reference has incompatible sweep steps")
                    fitted = []
                    for step, chosen in zip(local_animation.steps, leader_animation.steps):
                        span = step_duration_ms(step)
                        ratio = step_duration_ms(chosen) / span if span else 1
                        segments = []
                        for segment in step.segments:
                            timing = segment.timing
                            delay = round((timing.delay_ms or 0) * ratio)
                            end = round(((timing.delay_ms or 0) + timing.effective_duration_ms) * ratio)
                            segments.append(replace(segment, timing=replace(timing, duration_ms=end - delay,
                                delay_ms=delay if timing.delay_ms is not None else None)))
                        fitted.append(render_step(PaintStep(tuple(segments))))
                    native_lines = fitted
                # The packaged engine has only 2/8-LED builds. Expand local
                # rolls into indexed paints before playing a 1/3/4-LED track
                # on the eight-LED engine. Unused pixels remain black.
                if len(slots) not in (2, 8):
                    native_lines = [render_step(step) for step in
                                    _share_steps(native_lines, tuple(range(len(slots))))]
                native = "\n".join([*native_lines, "repeat"])
                reference = firmware.trace(native, 2 if len(slots) == 2 else 8)
            except ValueError:
                reference = None
            params = reference_settings.agent_animation_parameters(agent.provider)
            if motion in TRAVEL:
                # Multi-head and uniform profiles cannot be judged by argmax.
                eligible = (params.get("crests", 1 if motion != "marquee" else 2) == 1
                            and params.get("background_glow", 0) < 100
                            and params.get("head_width", 1) == 1)
                if eligible:
                    problems = sweep_errors(trace.cycle(), slots, motion)
                    check("sweep_path", not problems, f"{agent.provider} share {slots}: {problems}")
            if reference is not None:
                native_frames = local if len(agents) == 1 else reference.cycle()
                native_dark = dark_fraction(native_frames, tuple(range(len(slots))))
                allowance = DARK_FRACTION if motion in BOUNCE and len(slots) > 1 else max(DARK_FRACTION, native_dark + 0.02)
                measured = dark_fraction(local, tuple(range(len(slots))))
                check("dark_share", measured <= allowance,
                      f"{agent.provider} dark for {measured:.1%} of a cycle; allowed {allowance:.1%}")
            if motion in TEMPORAL and reference is not None and len(agents) > 1:
                check("temporal_period", abs(trace.period - reference.period) <= 4,
                      f"{agent.provider}: actual {trace.period}ms, native {reference.period}ms")
                actual_levels = [max(pixel) for frame in local for pixel in frame]
                native_levels = [max(pixel) for frame in reference.cycle() for pixel in frame[:len(slots)]]
                check("temporal_range", abs(max(actual_levels) - max(native_levels)) <= CHANNEL_TOLERANCE
                      and abs(min(actual_levels) - min(native_levels)) <= CHANNEL_TOLERANCE,
                      f"{agent.provider}: actual {min(actual_levels)}..{max(actual_levels)}, "
                      f"native {min(native_levels)}..{max(native_levels)}")
            if reference is not None and len(agents) > 1 and motion not in {"auto", "steady"}:
                expected = tuple(tuple(reference.frames[min(len(reference.frames) - 1,
                    (trace.period + index * trace.interval) // reference.interval)][:len(slots)])
                    for index in range(len(local)))
                error = frame_error(local, expected)
                check("share_fidelity", error <= CHANNEL_TOLERANCE,
                      f"{agent.provider} share {slots}: native timeline error {error}/255")
        # A different played mix is legal only when the explanation names it.
        if len(agents) > 1 and played != case.mix:
            check("fallback_warning", bool(warnings) and MIX_LABELS.get(played, played) in explanation["reason"],
                  f"{case.mix} became {played} without a named warning")
    except Exception as error:
        checks.add("exception")
        failures["exception"] = f"{type(error).__name__}: {error}"
    return Result(case, program, played, warnings, failures, checks, reassert_action)


def baseline_delta(actual, expected):
    actual = {key: set(values) for key, values in actual.items()}
    expected = {key: set(values) for key, values in expected.items()}
    keys = actual.keys() | expected.keys()
    return ({key: sorted(actual.get(key, set()) - expected.get(key, set())) for key in keys
             if actual.get(key, set()) - expected.get(key, set())},
            {key: sorted(expected.get(key, set()) - actual.get(key, set())) for key in keys
             if expected.get(key, set()) - actual.get(key, set())})
