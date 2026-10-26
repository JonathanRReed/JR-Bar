"""Plan provider animations and mixes within the device's program limits."""

from __future__ import annotations

import math
from dataclasses import dataclass, replace
from fractions import Fraction
from functools import lru_cache

from .animation import (
    ColorList,
    IndexedPaint,
    PaintStep,
    RollStep,
    Timing,
    WholeBar,
    format_time,
    read_program,
    render_step,
    step_duration_ms,
)
from .led_status import LedDisplayState, apply_brightness


@dataclass(frozen=True)
class MixPlan:
    state: LedDisplayState
    program: str
    requested_mix: str
    played: str
    reason: str
    warnings: tuple[str, ...] = ()


class CannotFit(ValueError):
    pass


MIX_LABELS = {
    "color_blend": "Smooth", "round_robin": "Everyone",
    "spatial_split": "Split", "cycle": "One at a Time",
    "alternate": "Alternate", "relay": "Relay", "weave": "Weave",
    "tide": "Tide", "classic": "Status Only",
}


def mix_catalog():
    def parameter(key, low, high, default, kind="number"):
        return {"key": key, "type": kind, "minimum": low, "maximum": high, "default": default}

    result = []
    for mode, name in MIX_LABELS.items():
        parameters = []
        if mode in {"alternate", "relay", "weave", "tide"}:
            parameters.append(parameter("duration_seconds", 0.3, 10.0, 2.2))
        if mode in {"relay", "weave", "tide"}:
            parameters.append(parameter("width", 1, 8, 1, "integer"))
        if mode == "relay":
            parameters.append(parameter("softness", 0, 1, 0.2))
        result.append({"id": mode, "name": name, "parameters": parameters})
    return result


def _number(values, key, default, low, high, warnings):
    value = values.get(key, default)
    if type(value) not in (float, int) or (type(value) is float and not math.isfinite(value)):
        warnings.append(f"{key} was rejected; using {default}.")
        return default
    bounded = max(low, min(high, value))
    if bounded != value:
        warnings.append(f"{key} was clamped to {bounded}.")
    return bounded


def mix_parameters(settings, mode, warnings=None):
    warnings = [] if warnings is None else warnings
    values = settings.mix_parameters.get(mode, {})
    known = {item["key"] for row in mix_catalog() if row["id"] == mode for item in row["parameters"]}
    for key in values.keys() - known:
        warnings.append(f"{key} was rejected for {MIX_LABELS[mode]}.")
    result = {"duration_seconds": settings.effective_speed_seconds(mode), "width": 1, "softness": 0.2}
    for key, low, high in (("duration_seconds", 0.3, 10.0), ("width", 1, 8), ("softness", 0, 1)):
        if key in known:
            result[key] = _number(values, key, result[key], low, high, warnings)
    width = result["width"]
    result["width"] = round(width)
    if width != result["width"]:
        warnings.append(f"width was rounded to {result['width']} LEDs.")
    return result


def _compact_paint(step, count):
    assignments = {}
    for segment in step.segments:
        if isinstance(segment, WholeBar):
            pairs = enumerate([segment.color] * count)
        elif isinstance(segment, ColorList):
            pairs = enumerate([*segment.colors, *(["off"] * max(0, count - len(segment.colors)))])
        else:
            pairs = segment.assignments
        for index, color in pairs:
            assignments[index] = ("#000000" if color == "off" else color, segment.timing)
    groups = {}
    for index, (color, timing) in sorted(assignments.items()):
        groups.setdefault(timing, []).append((index, color))
    segments = []
    for timing, pairs in groups.items():
        if (len(pairs) == count and [index for index, _ in pairs] == list(range(count))
                and timing.duration_ms != 0):
            colors = tuple(color for _, color in pairs)
            segment = WholeBar(colors[0], timing) if len(set(colors)) == 1 else ColorList(colors, timing)
        else:
            segment = IndexedPaint(tuple(pairs), timing)
        segments.append(segment)
    return PaintStep(tuple(segments))


def _checked(lines, count):
    from .colors import _fits_with_brightness

    animation, problems = read_program("\n".join(lines))
    if any(problem.severity == "error" and problem.code not in {"too-long", "too-many-lines"}
           for problem in problems):
        raise CannotFit("the provider program is invalid")
    rendered = []
    for step in animation.steps:
        original = render_step(step)
        compact = render_step(_compact_paint(step, count)) if isinstance(step, PaintStep) else original
        rendered.append(min((original, compact), key=len))
    text = "\n".join([*rendered, "repeat"])
    if not _fits_with_brightness(text):
        raise CannotFit("the program exceeds 512 bytes or 20 lines")
    return text


def _safe_program(program, count, warnings):
    from .colors import _fits_with_brightness
    from .presentation_compiler import compile_presentation_program

    compiled = compile_presentation_program(program, led_count=count)
    if not compiled.accepted:
        raise CannotFit("the presentation safety compiler refused the program")
    if not _fits_with_brightness(compiled.program):
        raise CannotFit("safe timing leaves no room for the device brightness line")
    if compiled.reasons:
        warnings.append("The safety compiler adjusted the timing: " + ", ".join(compiled.reasons) + ".")
    return compiled.program


def _body(agent, settings, count, *, compact=False):
    from . import colors as c
    from .motion_shapes import render_motion

    chosen = settings.agent_animation(agent.provider)
    if chosen == c.PROVIDER_ANIMATION_AUTO:
        if compact and settings.animation_style(c.MODE_WORKING) == c.ANIMATION_STYLE_ROLL:
            from .motion_shapes import CHASE_TAIL, travelling_wave

            cycle = settings.agent_cycle_ms(agent.provider,
                round(settings.effective_speed_seconds(settings.mix_mode) * 1000))
            return travelling_wave(c._peak_for_state(agent.color, agent.state, settings),
                led_count=count, lap_ms=cycle, tail=CHASE_TAIL, laps=1, lead_ms=250)
        program = c._single_agent_program(agent.color, agent.state,
            settings=settings, led_count=count, brightness=255, provider=agent.provider)
        lines = [line for line in program.splitlines() if not line.startswith("repeat")]
        if compact:
            # One lap is enough inside a share; solo keeps the classic program.
            seen_roll = False
            kept = []
            for line in lines:
                if line.startswith("roll-"):
                    if seen_roll:
                        continue
                    seen_roll = True
                kept.append(line)
            return kept
        return lines
    tempo_mode = settings.mix_mode if compact else c.BLEND_MODE_CYCLE
    cycle = settings.agent_cycle_ms(agent.provider, round(settings.effective_speed_seconds(tempo_mode) * 1000))
    motion = c.agent_motion(agent.state, cycle_ms=cycle, provider=agent.provider, settings=settings)
    if chosen != c.PROVIDER_ANIMATION_AUTO and motion != chosen:
        raise CannotFit(f"{agent.provider}'s {chosen} is too fast to play safely")
    params = settings.agent_animation_parameters(agent.provider)
    head = c.TOOL_TINT_COLORS.get(settings.render_tool_family) if settings.tint_by_tool else None
    if count == 1 and chosen == "kitt":
        return [f"{c._floor_for_state(agent.color, agent.state, settings)} {cycle // 2}ms cosine",
                f"{c._peak_for_state(agent.color, agent.state, settings)} {cycle - cycle // 2}ms cosine"]
    return render_motion(
        motion,
        c._peak_for_state(agent.color, agent.state, settings),
        c._floor_for_state(agent.color, agent.state, settings),
        led_count=count, cycle_ms=cycle, params=params,
        dot_travel=settings.render_dot_travel,
        ceiling=settings.fade_range("working")[1], strict=True, compact=compact, head=head,
    )


def _segments_at(step, slots):
    """Map a whole provider program into its physical LED share."""
    mapped = []
    for segment in step.segments:
        if isinstance(segment, WholeBar):
            pairs = tuple((index, segment.color) for index in slots)
        elif isinstance(segment, ColorList):
            pairs = tuple(
                (index, segment.colors[local] if local < len(segment.colors) else "off")
                for local, index in enumerate(slots)
            )
        else:
            pairs = tuple(
                (slots[index], color) for index, color in segment.assignments
                if index < len(slots)
            )
        if pairs:
            mapped.append(IndexedPaint(tuple((index, "#000000" if color == "off" else color)
                                            for index, color in pairs), segment.timing))
    return mapped


def _share_steps(lines, slots, roll_grid=None):
    animation, problems = read_program("\n".join(lines))
    if any(problem.severity == "error" for problem in problems):
        raise CannotFit("the provider program could not be mapped to its share")
    steps = []
    current = ["off"] * len(slots)
    for step in animation.steps:
        if isinstance(step, PaintStep):
            steps.append(PaintStep(tuple(_segments_at(step, slots))))
            # Needed only by a following roll. Pulse returns to its start.
            for segment in step.segments:
                if segment.timing.easing == "pulse":
                    continue
                if isinstance(segment, WholeBar):
                    current = [segment.color] * len(slots)
                elif isinstance(segment, ColorList):
                    current = list(segment.colors[:len(slots)])
                    current += ["off"] * (len(slots) - len(current))
                else:
                    for index, color in segment.assignments:
                        if index < len(current):
                            current[index] = color
        elif isinstance(step, RollStep):
            # A global roll would move the other provider's LEDs. Express
            # the same linear neighbour crossfades inside this share.
            if step.easing not in (None, "linear"):
                raise CannotFit("a curved roll cannot run inside a separate share")
            from .motion_shapes import mix

            count = len(slots)
            grid = roll_grid or [Fraction(index, count) for index in range(1, count + 1)]
            previous = 0
            for point in grid:
                position = point * count
                turns = int(position)
                fraction = float(position - turns)
                sign = 1 if step.direction == "roll-left" else -1
                def rotated(offset):
                    return [current[(index + sign * offset) % count] for index in range(count)]
                left, right = rotated(turns), rotated(turns + 1)
                colors = [mix(a, b, fraction) for a, b in zip(left, right)]
                end = round(point * step.duration_ms)
                steps.append(PaintStep((IndexedPaint(tuple(zip(slots, colors)),
                    Timing(end - previous, "linear")),)))
                previous = end
    return steps


def _share_frame(steps, count, fraction, *, firmware_curves=False, warm=True):
    """Evaluate a share at a cycle fraction, including its returning frame."""
    from .motion_shapes import mix

    total = sum(step_duration_ms(step) for step in steps)
    current = ["#000000"] * count
    # A pulse returns to its starting colour. Warm one complete cycle so
    # the first sample has the same baseline as every later cycle.
    for target in ((total, fraction * total) if warm else (fraction * total,)):
        elapsed = 0
        for step in steps:
            span = step_duration_ms(step)
            before = current[:]
            for segment in step.segments:
                timing = segment.timing
                local = target - elapsed - (timing.delay_ms or 0)
                if local < 0:
                    continue
                duration = timing.effective_duration_ms
                amount = min(1.0, local / duration) if duration else 1.0
                if firmware_curves:
                    from .linked_sync import curve_weight

                    amount = curve_weight(timing.easing, amount)
                elif timing.easing == "pulse":
                    amount = (1 - math.cos(2 * math.pi * amount)) / 2
                elif timing.easing == "cosine":
                    amount = (1 - math.cos(math.pi * amount)) / 2
                elif timing.easing == "none":
                    amount = 1.0
                for index, color in segment.assignments:
                    current[index] = mix(before[index], color, amount)
            if target < elapsed + span:
                break
            elapsed += span
    return current


KEYFRAME_MAX_ERROR = 24


@lru_cache(maxsize=256)
def _keyframe_fidelity(lines, count, period):
    """Measure 8-bit error against the native clock, never a retimed reference.

    Check every 20 ms over a native or Studio cycle, whichever is longer,
    plus both sides of every native boundary. Cache by rendered bytes so a
    daemon refresh does not repeat the measurement for unchanged settings.
    """
    from .motion_shapes import _channels

    local = _share_steps(lines, tuple(range(count)))
    native_period = sum(step_duration_ms(step) for step in local)
    frames = [_share_frame(local, count, Fraction(index, 4)) for index in range(5)]
    keyframes = []
    previous = 0
    for index in range(5):
        colors = frames[index % 4]
        end = round(index * period / 4)
        keyframes.append(PaintStep((IndexedPaint(tuple(enumerate(colors)), Timing(end - previous, "linear")),)))
        previous = end
    horizon = max(period, native_period)
    times = set(range(0, horizon + 1, 20)) | {horizon}
    elapsed = 0
    for step in local:
        for segment in step.segments:
            start = elapsed + (segment.timing.delay_ms or 0)
            end = start + segment.timing.effective_duration_ms
            times.update(max(0, min(horizon, value + offset))
                         for value in (start, end) for offset in (-1, 0, 1))
        elapsed += step_duration_ms(step)
    error = 0
    for time in times:
        for warm in (False, True):
            native = _share_frame(local, count, Fraction(time % native_period, native_period),
                firmware_curves=True, warm=warm or time >= native_period)
            simplified = _share_frame(keyframes, count, Fraction(time % period, period), warm=warm or time >= period)
            error = max(error, *(abs(a - b) for left, right in zip(native, simplified)
                                for a, b in zip(_channels(left), _channels(right))))
    return frames, native_period, error


def _keyframe_shares(agents, settings, slots, count, warnings):
    """Use four linear phases only for equal Studio periods that pass fidelity."""
    from .colors import PROVIDER_ANIMATION_LABELS

    default = round(settings.effective_speed_seconds(settings.mix_mode) * 1000)
    chosen = [settings.agent_cycle_ms(agent.provider, default) for agent in agents
              if settings.agent_animation(agent.provider) != "auto"]
    if len(set(chosen)) > 1:
        raise CannotFit("the chosen Studio cycles have different durations")
    period = chosen[0] if chosen else default
    frames, measurements = [], []
    for agent, share in zip(agents, slots):
        samples, native_period, error = _keyframe_fidelity(
            tuple(_body(agent, settings, len(share), compact=True)), len(share), period)
        frames.append(samples)
        measurements.append((native_period, error))
    labels = list(dict.fromkeys(PROVIDER_ANIMATION_LABELS.get(settings.agent_animation(agent.provider),
        settings.agent_animation(agent.provider)) for agent in agents))
    if any(error > KEYFRAME_MAX_ERROR for _native_period, error in measurements):
        names = " and ".join(labels) if len(labels) > 1 else labels[0] + " animations"
        raise CannotFit(names + " take turns because they can't share the strip without losing their motion")
    lines = []
    previous = 0
    for index in range(5):
        colors = ["#000000"] * count
        for share, samples in zip(slots, frames):
            for local, physical in enumerate(share):
                colors[physical] = samples[index % 4][local]
        boundary = round(index * period / 4)
        span = boundary - previous
        lines.append(" ".join(colors) + f" {format_time(span)} linear")
        previous = boundary
    program = _checked(lines, count)
    for agent, (native_period, error) in zip(agents, measurements):
        label = PROVIDER_ANIMATION_LABELS.get(settings.agent_animation(agent.provider), settings.agent_animation(agent.provider))
        others = " and ".join(name for name in labels if name != label)
        warning = f"{label} is simplified slightly to share the strip" + (f" with {others}" if others else "")
        if native_period != period:
            warning += f"; its native {native_period} ms cycle plays in {period} ms"
        if (error or native_period != period) and warning + "." not in warnings:
            warnings.append(warning + ".")
    return program


def _shares(agents, settings, count, mode, warnings=None):
    if len(agents) > count:
        raise CannotFit(f"{len(agents)} providers need more than {count} LED shares")
    # Remainders follow attention, then observed start, without moving the
    # providers' stable display order.
    need = {LedDisplayState.ASK: 0, LedDisplayState.FAILED: 1}
    rank = sorted(range(len(agents)), key=lambda index: (
        need.get(agents[index].state, 2),
        agents[index].started_at if agents[index].started_at is not None else float("inf"), agents[index].identity, index))
    sizes = [count // len(agents)] * len(agents)
    for index in rank[:count % len(agents)]:
        sizes[index] += 1
    if mode == "spatial_split":
        slots = []
        start = 0
        for size in sizes:
            slots.append(tuple(range(start, start + size)))
            start += size
    else:
        slots = [tuple(index for index in range(count) if index % len(agents) == agent)
                 for agent in range(len(agents))]
    for agent, share in zip(agents, slots):
        if len(share) == 1 and settings.agent_animation(agent.provider) not in {
            "auto", "breathe", "heartbeat", "steady", "blink", "kitt"
        }:
            raise CannotFit(f"{agent.provider}'s animation needs more than one LED in its share")
    grid = sorted({Fraction(index, len(share)) for share in slots
                   for index in range(1, len(share) + 1)})
    tracks = [_share_steps(_body(agent, settings, len(share), compact=True), share, grid)
              for agent, share in zip(agents, slots)]
    explicit = [index for index, agent in enumerate(agents)
                if settings.agent_animation(agent.provider) not in {"auto", "steady"}]
    if explicit:
        chosen_spans = [step_duration_ms(step) for step in tracks[explicit[0]]]
        period = sum(chosen_spans)
        common = all(
            [step_duration_ms(step) for step in tracks[index]] == chosen_spans
            for index in explicit)
        if common:
            # Automatic has no chosen clock. Follow the chosen steps so
            # their curves and native period remain untouched, including
            # renderer rounding and the slower two-LED scanner cadence.
            for index, (agent, share) in enumerate(zip(agents, slots)):
                if settings.agent_animation(agent.provider) != "auto":
                    continue
                local = _share_steps(_body(agent, settings, len(share), compact=True),
                    tuple(range(len(share))))
                elapsed = 0
                synchronized = []
                for span in chosen_spans:
                    elapsed += span
                    colors = _share_frame(local, len(share), Fraction(elapsed, period))
                    synchronized.append(PaintStep((IndexedPaint(tuple(zip(share, colors)),
                        Timing(span, "linear")),)))
                tracks[index] = synchronized
    moving = [index for index, agent in enumerate(agents)
              if settings.agent_animation(agent.provider) != "steady"]
    if moving:
        spans = [step_duration_ms(step) for step in tracks[moving[0]]]
        for index, agent in enumerate(agents):
            if settings.agent_animation(agent.provider) == "steady":
                first = PaintStep(tuple(replace(segment, timing=Timing(spans[0], "cosine"))
                                        for segment in tracks[index][0].segments))
                tracks[index] = [first, *[PaintStep(()) for _ in spans[1:]]]
    # Exact geometry and timing, or an explicit fallback. Stretching one
    # track to another's tempo loses Studio's duration and heartbeat gaps.
    spans = [[step_duration_ms(step) for step in tracks[index]]
             for index in (moving or range(len(tracks)))]
    if any(span != spans[0] for span in spans[1:]):
        return _keyframe_shares(agents, settings, slots, count, warnings if warnings is not None else [])
    lines = [render_step(PaintStep(tuple(
        segment for step in group for segment in step.segments
    ))) for group in zip(*tracks)]
    return _checked(lines, count)


def _cycle(agents, settings, count, warnings):
    from . import colors as c
    from .motion_shapes import _number, _whole, shade

    turns = []
    for agent in agents:
        if settings.agent_animation(agent.provider) == "kitt" and count > 2:
            # A compact pass in each direction leaves room for every colour.
            # Solo and simultaneous shares retain the full bouncing beam.
            peak = c._peak_for_state(agent.color, agent.state, settings)
            params = settings.agent_animation_parameters(agent.provider)
            beam = _whole(params, "beam_width", 3, 2, 6)
            overlap = _number(params, "overlap", 0.5, 0.1, 1)
            glow = _number(params, "background_glow", 0, 0, 100) / 100
            tail = tuple(max(glow, max(0, 1 - min(index, count - index) / (beam / 2)) ** (1.3 - overlap))
                         for index in range(count))
            cycle = settings.agent_cycle_ms(agent.provider, c.provider_cycle_ms(agent.provider, settings))
            lead = min(200, max(1, cycle // 10))
            sweep = max(1, (cycle - lead) // 2)
            body = [" ".join(shade(peak, level) for level in tail) + f" {lead}ms cosine",
                    f"roll-right {sweep}ms linear", f"roll-left {sweep}ms linear"]
        else:
            body = _body(agent, settings, count, compact=True)
        animation, _ = read_program("\n".join(body))
        duration = sum(step_duration_ms(step) for step in animation.steps)
        repeats = max(1, round(4000 / max(1, duration)))
        turns.append((animation.steps, duration, repeats))

    def render_turns():
        lines = []
        for steps, duration, repeats in turns:
            scale = 4000 / max(1, duration * repeats)
            for step in steps * repeats:
                if isinstance(step, PaintStep):
                    step = PaintStep(tuple(replace(segment, timing=replace(segment.timing,
                        duration_ms=max(0, round(segment.timing.effective_duration_ms * scale)),
                        delay_ms=(round(segment.timing.delay_ms * scale)
                                  if segment.timing.delay_ms is not None else None)))
                        for segment in step.segments))
                elif isinstance(step, RollStep):
                    step = replace(step, duration_ms=max(1, round(step.duration_ms * scale)))
                lines.append(render_step(step))
        return _checked(lines, count)

    stretched = False
    while True:
        try:
            program = render_turns()
            if stretched:
                warnings.append("One at a Time stretches fewer cycles to four seconds to fit the device.")
            return program
        except CannotFit:
            candidates = [index for index, (_steps, _duration, repeats) in enumerate(turns) if repeats > 1]
            if not candidates:
                raise
            index = max(candidates, key=lambda index: turns[index][2])
            steps, duration, repeats = turns[index]
            turns[index] = steps, duration, repeats - 1
            stretched = True


def _multi_color(agents, settings, count, mode, warnings):
    from .colors import _peak_for_state
    from .motion_shapes import shade

    values = mix_parameters(settings, mode, warnings)
    duration = max(300, round(values["duration_seconds"] * 1000))
    colors = [_peak_for_state(agent.color, agent.state, settings) for agent in agents]
    width = values["width"]
    if mode == "alternate":
        return _checked([f"{color} {format_time(duration)} cosine" for color in colors], count)
    if mode == "weave":
        profile = [colors[(index // width) % len(colors)] for index in range(count)]
        if len(set(profile)) < len(colors):
            raise CannotFit("the stripe width leaves no LED for every provider colour")
        return _checked([" ".join(profile) + " 300ms cosine", f"roll-right {format_time(duration)} linear"], count)
    if mode == "relay":
        if count <= 2:
            raise CannotFit("a scanner beam needs at least 4 LEDs")
        lines = []
        # One pass per provider, alternating the beam's direction. The
        # next pass takes the next provider colour, unlike Automatic.
        for turn, color in enumerate(colors):
            profile = [shade(color, max(values["softness"], 1 - index / width))
                       for index in range(count)]
            if turn % 2:
                profile.reverse()
            lines.append(" ".join(profile) + " 300ms cosine")
            direction = "roll-left" if turn % 2 else "roll-right"
            lines.append(f"{direction} {format_time(duration)} linear")
        return _checked(lines, count)
    if mode == "tide":
        if count == 2:
            if len(colors) > 2:
                raise CannotFit("the Dot tide has only two endpoints")
            return _checked([f"{colors[0]} {colors[1]} {format_time(duration)} cosine",
                             f"{colors[1]} {colors[0]} {format_time(duration)} cosine"], count)
        step_ms = max(60, duration // max(1, count // 2))
        def profile(phase):
            return [colors[(min(index, count - 1 - index) + phase) % len(colors)]
                    for index in range(count)]
        if len(set(profile(0))) < len(colors):
            raise CannotFit("the inward tide has too few positions for every provider colour")
        lines = [" ".join(profile(0)) + " 300ms cosine"]
        for phase in (1, 0):
            targets = profile(phase)
            segments = []
            for distance in range((count + 1) // 2):
                indices = sorted({distance, count - 1 - distance})
                pairs = " ".join(f"{index}:{targets[index]}" for index in indices)
                segments.append(f"{pairs} {format_time(step_ms * width)} cosine {format_time(distance * step_ms)}")
            lines.append("; ".join(segments))
        return _checked(lines, count)
    raise ValueError(mode)


def selected_agents(agents):
    """Asks stay individual. Active providers own the ordinary animation."""
    asks = [agent for agent in agents if agent.state is LedDisplayState.ASK]
    if asks:
        return asks
    working = [agent for agent in agents if agent.state is LedDisplayState.WORKING]
    candidates = working or agents
    return list(candidates)


def _provider_parameter_warnings(agents, settings):
    from .effect_registry import _PROVIDER_PARAMETER_METADATA, EffectRegistryError

    warnings = []
    for agent in agents:
        chosen = settings.agent_animation(agent.provider)
        specs = {spec.name: spec for spec in _PROVIDER_PARAMETER_METADATA.get(chosen, ())}
        for key, value in settings.agent_animation_parameters(agent.provider).items():
            spec = specs.get(key)
            if spec is None:
                warnings.append(f"{agent.provider}'s {key} is not used by {chosen}.")
                continue
            try:
                spec.normalize(value)
            except EffectRegistryError:
                warnings.append(f"{agent.provider}'s {key} cannot play exactly; the renderer uses a safe default or bound.")
    return warnings


def plan_agent_mix(agents, settings, *, led_count=8, brightness=255):
    from . import colors as c

    mode = settings.mix_mode
    selected = selected_agents(agents)
    state = c._representative_state(selected)
    if led_count <= 0:
        return MixPlan(state, "", mode, "off", "No LED shares are available.")
    if not selected:
        state, program = c.program_for_snapshot((), colors=settings, led_count=led_count, brightness=brightness)
        return MixPlan(state, program, mode, "idle", "No provider is working.")
    if state is LedDisplayState.ASK:
        program = c._single_agent_program(settings.mode_color("ask"), state,
            settings=settings, led_count=led_count, brightness=brightness)
        return MixPlan(state, program, mode, "ask", "An ask needs you.")
    if mode in {"classic", "color_blend"}:
        if mode == "classic":
            state = c._representative_state(agents)
            color = (settings.rendered_error_color() if state is LedDisplayState.FAILED
                     else settings.mode_color(c._STATE_TO_MODE_KEY[state]))
        else:
            color = c.weighted_blend([(agent.color, float(agent.weight)) for agent in selected])
        return MixPlan(state, apply_brightness(color, brightness), mode, mode,
                       f"{MIX_LABELS[mode]} holds still. Asks still blink.")
    warnings = _provider_parameter_warnings(selected, settings)
    if len(selected) > 1 and len({agent.provider for agent in selected}) == 1:
        color = c.weighted_blend([(agent.color, float(agent.weight)) for agent in selected])
        selected = [replace(selected[0], color=color, state=state)]
    if len(selected) == 1:
        agent = selected[0]
        program = c._single_agent_program(agent.color, state, settings=settings,
            led_count=led_count, brightness=brightness, provider=agent.provider)
        played = settings.agent_animation(agent.provider) if state is LedDisplayState.WORKING else state.value
        if state is LedDisplayState.WORKING and played != c.PROVIDER_ANIMATION_AUTO:
            actual = c.agent_motion(state, cycle_ms=c.provider_cycle_ms(agent.provider, settings),
                provider=agent.provider, settings=settings)
            if actual != played:
                warnings.append(f"{agent.provider}'s {played} cannot play exactly at this speed; showing {actual}.")
                played = actual
        return MixPlan(state, program, mode, played, f"{agent.provider} is the only working provider.", tuple(warnings))
    if not any(agent.state is LedDisplayState.WORKING for agent in selected):
        renderer = {
            "cycle": c._cycle_program, "spatial_split": c._spatial_split_program,
            "round_robin": c._round_robin_program, "relay": c._relay_program,
        }.get(mode, c._color_blend_program)
        program = renderer(selected, led_count=led_count, brightness=brightness, settings=settings)
        return MixPlan(state, program, mode, "status", "No provider is working.")
    names = " and ".join(agent.provider for agent in selected)
    requested = mode
    attempts = [mode]
    if mode in ("spatial_split", "round_robin"):
        attempts += ["cycle"]
    if mode not in ("alternate", "classic", "color_blend"):
        attempts += ["alternate"]
    if mode != "color_blend":
        attempts += ["color_blend"]
    for attempt in attempts:
        try:
            if attempt in ("spatial_split", "round_robin"):
                program = _shares(selected, settings, led_count, attempt, warnings)
                if led_count < 2 * len(selected) and any(settings.agent_animation(agent.provider) == "kitt" for agent in selected):
                    warnings.append("Knight Rider shows the beam's rise and fall on a one-LED share.")
            elif attempt == "cycle":
                program = _cycle(selected, settings.with_blend_mode("cycle"), led_count, warnings)
                if any(settings.agent_animation(agent.provider) == "kitt" for agent in selected) and led_count > 2:
                    warnings.append("One at a Time uses a circulating Knight Rider scan to fit all providers.")
            elif attempt == "classic":
                program = settings.mode_color(c._STATE_TO_MODE_KEY[state])
            elif attempt == "color_blend":
                program = c._color_blend_program(selected, led_count=led_count,
                    brightness=255, settings=settings)
            else:
                program = _multi_color(selected, settings, led_count, attempt, warnings)
            if not c._fits_with_brightness(program):
                raise CannotFit("the program exceeds 512 bytes or 20 lines")
            program = _safe_program(program, led_count, warnings)
            reason = (f"{MIX_LABELS[attempt]} plays because {names} are working."
                      if attempt == requested else f"Showing {MIX_LABELS[attempt]} because the requested program cannot fit exactly.")
            if attempt == "classic":
                reason = "Status Only shows the current state colour with no animation."
            return MixPlan(state, apply_brightness(program, brightness), requested, attempt, reason, tuple(warnings))
        except CannotFit as error:
            warnings.append(f"{MIX_LABELS[attempt]} cannot play exactly on {led_count} LEDs: {error}.")
    raise CannotFit("even Smooth exceeds the device budget")


def explain_what_plays(state, settings, *, led_count=8, ambient=None):
    """The same plan and program the ordinary agent display renders."""
    from . import colors as c
    from .ambient_layers import compose_ambient_layer

    projection = hasattr(state, "light_rows")
    agents = (c.projection_mix_agents(state, settings, led_count) if projection
              else c._active_agents(tuple(state), settings, led_count))
    plan = plan_agent_mix(agents, settings, led_count=led_count)
    _state, program = (c.program_for_projection(state, colors=settings, led_count=led_count)
                       if projection else c.program_for_snapshot(tuple(state), colors=settings, led_count=led_count))
    selected = selected_agents(agents)
    providers = [{"provider": agent.provider, "animation": settings.agent_animation(agent.provider),
                  "parameters": settings.agent_animation_parameters(agent.provider)} for agent in selected]
    chosen = [row for row in providers if row["animation"] != "auto"]
    cue_reason = None
    if chosen:
        row = chosen[0]
        label = c.PROVIDER_ANIMATION_LABELS.get(row["animation"], row["animation"])
        cue_reason = f"Ember is not shown because {row['provider']} has {label}."
        if ambient is not None and ambient.output.family.value == "turn_length_ember":
            ambient = None
    layered = compose_ambient_layer(program, plan.state, ambient)
    cue = None
    if layered != program:
        cue = {"id": ambient.output.family.value, "until": ambient.next_visual_change_at}
        cue_reason = "A short colour layer keeps the provider animation running."
    return {
        "led_count": led_count, "requested_mix": plan.requested_mix,
        "played": plan.played, "reason": plan.reason,
        "warnings": list(plan.warnings), "providers": providers,
        "program": layered, "cue": cue, "cue_reason": cue_reason,
    }
