"""Plan provider animations and mixes within the device's program limits."""

from __future__ import annotations

import math
from dataclasses import dataclass, replace

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
class ActiveAgentGroup:
    provider: str
    root: object
    members: tuple


def active_agent_groups(state) -> tuple[ActiveAgentGroup, ...]:
    """L2 integration point. Use the existing projection's worker roll-up.

    Each light row is already a root or a worker stand-in. No folder or
    process ancestry is used to infer a parent here.
    """
    rows = getattr(state, "light_rows", state)
    return tuple(
        ActiveAgentGroup(row.provider, row, (getattr(row, "source_status", row),))
        for row in rows
    )


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


def _number(values, key, default, low, high):
    value = values.get(key, default)
    if type(value) not in (float, int) or not math.isfinite(value):
        return default
    return max(low, min(high, value))


def mix_parameters(settings, mode):
    values = settings.mix_parameters.get(mode, {})
    return {
        "duration_seconds": _number(
            values, "duration_seconds", settings.effective_speed_seconds(mode), 0.3, 10.0
        ),
        "width": round(_number(values, "width", 1, 1, 8)),
        "softness": _number(values, "softness", 0.2, 0, 1),
    }


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

    tempo_mode = settings.mix_mode if compact else c.BLEND_MODE_CYCLE
    cycle = settings.agent_cycle_ms(agent.provider, round(settings.effective_speed_seconds(tempo_mode) * 1000))
    motion = c.agent_motion(
        agent.state, cycle_ms=cycle, provider=agent.provider, settings=settings
    )
    chosen = settings.agent_animation(agent.provider)
    if chosen == c.PROVIDER_ANIMATION_AUTO:
        motion = c._speed_safe_motion({
            c.ANIMATION_STYLE_PULSE: c.MOTION_BREATHE,
            c.ANIMATION_STYLE_ROLL: c.MOTION_CHASE,
            c.ANIMATION_STYLE_BLINK: c.MOTION_BLINK,
            c.ANIMATION_STYLE_SOLID: c.MOTION_STEADY,
        }[settings.animation_style(c.MODE_WORKING)], cycle_ms=cycle)
    if chosen != c.PROVIDER_ANIMATION_AUTO and motion != chosen:
        raise CannotFit(f"{agent.provider}'s {chosen} is too fast to play safely")
    params = settings.agent_animation_parameters(agent.provider)
    head = c.TOOL_TINT_COLORS.get(settings.render_tool_family) if settings.tint_by_tool else None
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


def _share_steps(lines, slots):
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
            count = len(slots)
            for index in range(count):
                duration = round((index + 1) * step.duration_ms / count) - round(index * step.duration_ms / count)
                if step.direction == "roll-left":
                    current = current[1:] + current[:1]
                else:
                    current = current[-1:] + current[:-1]
                steps.append(PaintStep((IndexedPaint(
                    tuple(zip(slots, current)), Timing(duration, "linear")
                ),)))
    return steps


def _shares(agents, settings, count, mode):
    if len(agents) > count:
        raise CannotFit(f"{len(agents)} providers need more than {count} LED shares")
    if mode == "spatial_split":
        slots = [tuple(range(index * count // len(agents), (index + 1) * count // len(agents)))
                 for index in range(len(agents))]
    else:
        slots = [tuple(range(index, count, len(agents))) for index in range(len(agents))]
    for agent, share in zip(agents, slots):
        if len(share) < 2 and settings.agent_animation(agent.provider) not in {"auto", "breathe", "heartbeat", "steady", "blink"}:
            raise CannotFit(f"{agent.provider}'s animation needs more than one LED in its share")
    tracks = [_share_steps(_body(agent, settings, len(share), compact=True), share)
              for agent, share in zip(agents, slots)]
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
        raise CannotFit("the providers' independent timelines cannot share these device lines exactly")
    lines = [render_step(PaintStep(tuple(
        segment for step in group for segment in step.segments
    ))) for group in zip(*tracks)]
    return _checked(lines, count)


def _cycle(agents, settings, count):
    return _checked([line for agent in agents for line in _body(agent, settings, count, compact=True)], count)


def _multi_color(agents, settings, count, mode):
    from .colors import _peak_for_state
    from .motion_shapes import shade

    values = mix_parameters(settings, mode)
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
        lines = []
        for turn, color in enumerate(colors):
            other = colors[(turn + 1) % len(colors)]
            lines.append(" ".join(color if index < count / 2 else other for index in range(count)) + " 300ms cosine")
            segments = []
            step_ms = max(60, duration // max(1, count // 2))
            for index in range(count):
                distance = min(index, count - 1 - index)
                target = other if index < count / 2 else color
                segments.append(f"{index}:{target} {format_time(step_ms * width)} cosine {format_time(distance * step_ms)}")
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
    providers = {}
    for agent in candidates:
        prior = providers.get(agent.provider)
        if prior is None or agent.weight > prior.weight:
            providers[agent.provider] = agent
    return list(providers.values())


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
    if not any(agent.state is LedDisplayState.WORKING for agent in selected):
        if mode == "classic":
            program = apply_brightness(settings.mode_color(c._STATE_TO_MODE_KEY[state]), brightness)
            return MixPlan(state, program, mode, "classic", "Status Only shows the current state colour with no animation.")
        if len(selected) == 1:
            agent = selected[0]
            program = c._single_agent_program(agent.color, state, settings=settings,
                led_count=led_count, brightness=brightness, provider=agent.provider)
            return MixPlan(state, program, mode, state.value, "No provider is working.")
        segments = []
        for index in range(led_count):
            agent = selected[index * len(selected) // led_count]
            color = c._floor_for_state(agent.color, agent.state, settings) if agent.state is LedDisplayState.DONE else c._peak_for_state(agent.color, agent.state, settings)
            segments.append(f"{index}:{color}")
        return MixPlan(state, apply_brightness(" ".join(segments), brightness), mode,
            "status", "No provider is working. Status colours stay still.")
    warnings = []
    if len(selected) == 1:
        agent = selected[0]
        motion = settings.agent_animation(agent.provider)
        if agent.state is LedDisplayState.WORKING:
            try:
                program = _checked(_body(agent, settings, led_count), led_count)
                program = _safe_program(program, led_count, warnings)
                return MixPlan(state, apply_brightness(program, brightness), mode, motion,
                    f"{agent.provider} is the only working provider.", tuple(warnings))
            except CannotFit as error:
                warnings.append(f"{agent.provider}'s {motion} cannot play exactly: {error}.")
    names = " and ".join(agent.provider for agent in selected)
    requested = mode
    if len(selected) == 1:
        mode = "color_blend"
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
                program = _shares(selected, settings, led_count, attempt)
            elif attempt == "cycle":
                program = _cycle(selected, settings.with_blend_mode("cycle"), led_count)
            elif attempt == "classic":
                program = settings.mode_color(c._STATE_TO_MODE_KEY[state])
            elif attempt == "color_blend":
                program = c._color_blend_program(selected, led_count=led_count,
                    brightness=255, settings=settings)
            else:
                program = _multi_color(selected, settings, led_count, attempt)
            if not c._fits_with_brightness(program):
                raise CannotFit("the program exceeds 512 bytes or 20 lines")
            program = _safe_program(program, led_count, warnings)
            reason = (f"{MIX_LABELS[attempt]} plays because {names} are working."
                      if not warnings else f"Showing {MIX_LABELS[attempt]} because the requested program cannot fit exactly.")
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
              else c._active_agents(c._statuses_for_strip(tuple(state), led_count), settings))
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
