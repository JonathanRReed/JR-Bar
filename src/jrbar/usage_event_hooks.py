"""Usage hooks: run a person's own program when a usage event happens.

CodexBar's external event hooks (MIT, reimplemented here) are the model.
A hook is a RULE in ``usage_hooks.rules``: which event, optionally which
provider and below what remaining percent, and which absolute executable
to run with which arguments. Nothing runs until ``usage_hooks.enabled`` is
on.

Seven events, all edges rather than states, so a script needs no rate
limiting of its own:

  quota_low             a lane crossed its provider's low threshold downward
  quota_reached         a lane ran out
  quota_reset           a lane's window reset (confirmed: the same reset the
                        celebrations and the ``quota_reset`` wire event use,
                        with the same ``event_id``)
  usage_updated         a lane's remaining percent moved
  provider_unavailable  a collecting provider stopped answering
  provider_recovered    it answers again
  refresh_failed        a refresh came back with an error

``usage_updated``, ``refresh_failed`` and ``provider_unavailable`` are
limited to one run per 600 s for each rule, provider, account and lane.

How a hook runs, every time:

- never through a shell: argv is ``executable arguments...``;
- with a small environment: ``PATH HOME USER LOGNAME SHELL LANG LC_ALL
  LC_CTYPE TERM TMPDIR`` from the daemon, plus ``JRBAR_EVENT``,
  ``JRBAR_PROVIDER``, ``JRBAR_INSTANCE``, ``JRBAR_LANE``,
  ``JRBAR_REMAINING_PERCENT``, ``JRBAR_RESET_AT``, ``JRBAR_STATE`` and
  ``JRBAR_TIMESTAMP``. Nothing else the daemon holds (an API key in its
  environment) reaches the hook;
- with the event as JSON on stdin: ``{"v": 1, ...}`` with sorted keys,
  optional fields left out and no account labels;
- with a timeout that kills it, output discarded, one background thread
  per batch so a slow script cannot back up the daemon.

Limits fail closed: more than 32 rules and no rule runs; a rule with a
relative executable, more than 32 arguments or a string over 4 KiB never
runs; an event whose JSON is over 4 KiB is not delivered. A rule migrated
from the first version's single hook path (``argv: legacy``) keeps that
version's argv, ``executable EVENT PROVIDER LANE DETAIL``, and its five
events: ``usage_updated`` and ``refresh_failed`` reach it only if it names
them.
"""

from __future__ import annotations

import json
import os
import subprocess
import threading
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Any

from .provider_usage_platform import ProviderSourceState
from .usage_source_settings import (
    USAGE_HOOK_ANY_EVENT,
    USAGE_HOOK_EVENTS,
    normalize_usage_hooks,
)

HOOK_TIMEOUT_SECONDS = 15.0
HOOK_THROTTLE_SECONDS = 600.0
THROTTLED_EVENTS = frozenset({"usage_updated", "refresh_failed", "provider_unavailable"})
MAX_RULES = 32
MAX_ARGUMENTS = 32
MAX_STRING_BYTES = 4096
MAX_PAYLOAD_BYTES = 4096
PAYLOAD_VERSION = 1
#: The environment a hook may see from the daemon's own.
ENVIRONMENT_ALLOWLIST = (
    "PATH",
    "HOME",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "LC_ALL",
    "LC_CTYPE",
    "TERM",
    "TMPDIR",
)
#: The first version's five events: what a migrated ``legacy`` rule gets.
LEGACY_EVENTS = frozenset(
    {"quota_low", "quota_reached", "quota_reset", "provider_unavailable", "provider_recovered"}
)
#: A lane's remaining percent has to move at least this much to be an update.
USAGE_UPDATE_MIN_POINTS = 0.5

_ANSWERING = frozenset(
    {ProviderSourceState.READY, ProviderSourceState.STALE}
)
_SILENT = frozenset(
    {
        ProviderSourceState.ERROR,
        ProviderSourceState.UNAVAILABLE,
        ProviderSourceState.RATE_LIMITED,
    }
)
_FAILED = _SILENT | frozenset({ProviderSourceState.NEEDS_SIGN_IN})


@dataclass(frozen=True, slots=True)
class UsageHookEvent:
    name: str
    provider_id: str
    lane_id: str
    detail: str
    source_instance_id: str = "default"
    remaining_percent: float | None = None
    reset_at: float | None = None
    state: str | None = None
    threshold_percent: float | None = None
    event_id: str | None = None
    label: str | None = None
    occurred_at: float | None = None

    def payload(self, *, now: float | None = None) -> dict[str, Any]:
        """The stdin document: v1 fields, optional ones left out."""
        document: dict[str, Any] = {
            "v": PAYLOAD_VERSION,
            "event": self.name,
            "provider": self.provider_id,
            "instance": self.source_instance_id,
            "timestamp": round(self.occurred_at if self.occurred_at is not None else (now or time.time()), 3),
        }
        optional = {
            "lane": self.lane_id or None,
            "label": self.label,
            "remaining_percent": None if self.remaining_percent is None else round(self.remaining_percent, 2),
            "reset_at": None if self.reset_at is None else round(self.reset_at, 3),
            "state": self.state,
            "threshold_percent": self.threshold_percent,
            "event_id": self.event_id,
        }
        document.update({key: value for key, value in optional.items() if value is not None})
        return document


def encode_payload(event: UsageHookEvent, *, now: float | None = None) -> bytes:
    """Sorted, compact JSON with a trailing newline."""
    text = json.dumps(event.payload(now=now), sort_keys=True, separators=(",", ":"), allow_nan=False)
    return (text + "\n").encode("utf-8")


def _lanes(snapshots) -> dict[tuple[str, str, str], Any]:
    return {
        (snapshot.provider_id, snapshot.source_instance_id, lane.lane_id): lane
        for snapshot in snapshots
        for lane in snapshot.lanes
        if lane.remaining_percent is not None
    }


def _state_word(snapshot) -> str:
    return snapshot.state.value


def detect_usage_hook_events(
    previous_snapshots,
    current_snapshots,
    *,
    thresholds: dict[object, float],
    reset_events=(),
) -> tuple[UsageHookEvent, ...]:
    """Transitions between two usage states, in a stable order.

    Both sides must have a value for a lane to fire quota edges: a lane
    appearing or vanishing is not a crossing. Provider availability edges
    need a definite state on both sides for the same reason. Resets come
    from ``reset_events``, the confirmed ones, never from a private rule.
    """
    events: list[UsageHookEvent] = []
    previous_lanes = _lanes(previous_snapshots)
    current_by_identity = {snapshot.identity: snapshot for snapshot in current_snapshots}
    for key, lane in sorted(_lanes(current_snapshots).items()):
        prior_lane = previous_lanes.get(key)
        if prior_lane is None:
            continue
        prior = prior_lane.remaining_percent
        current = lane.remaining_percent
        provider_id, source_instance_id, lane_id = key
        snapshot = current_by_identity.get((provider_id, source_instance_id))
        observed = snapshot.observed_at if snapshot is not None else None
        common = {
            "source_instance_id": source_instance_id,
            "remaining_percent": current,
            "reset_at": lane.reset_at,
            "state": _state_word(snapshot) if snapshot is not None else None,
            "label": lane.label,
            "occurred_at": observed,
        }
        threshold = thresholds.get(
            (provider_id, source_instance_id),
            thresholds.get(provider_id),
        )
        if threshold is not None and prior > threshold >= current:
            events.append(
                UsageHookEvent(
                    "quota_low",
                    provider_id,
                    lane_id,
                    f"{current:.0f}",
                    threshold_percent=float(threshold),
                    **common,
                )
            )
        if prior > 0.0 >= current:
            events.append(UsageHookEvent("quota_reached", provider_id, lane_id, "0", **common))
        if abs(current - prior) >= USAGE_UPDATE_MIN_POINTS:
            events.append(
                UsageHookEvent("usage_updated", provider_id, lane_id, f"{current:.0f}", **common)
            )
    # A reset is the confirmed one the celebrations use
    # (provider_usage_qol.confirm_reset_events), never a private jump rule:
    # the hook and the confetti used to disagree about what a reset was.
    current_lanes = _lanes(current_snapshots)
    for reset in reset_events:
        lane = current_lanes.get((reset.provider_id, reset.source_instance_id, reset.lane_id))
        remaining = lane.remaining_percent if lane is not None else None
        events.append(
            UsageHookEvent(
                "quota_reset",
                reset.provider_id,
                reset.lane_id,
                f"{remaining:.0f}" if remaining is not None else reset.label,
                reset.source_instance_id,
                remaining_percent=remaining,
                reset_at=lane.reset_at if lane is not None else None,
                state="ready",
                event_id=reset.event_id,
                label=reset.label,
                occurred_at=reset.occurred_at,
            )
        )
    previous_by_identity = {snapshot.identity: snapshot for snapshot in previous_snapshots}
    for snapshot in sorted(current_snapshots, key=lambda item: item.identity):
        prior_snapshot = previous_by_identity.get(snapshot.identity)
        if prior_snapshot is None:
            continue
        prior_state = prior_snapshot.state
        common = {
            "source_instance_id": snapshot.source_instance_id,
            "state": _state_word(snapshot),
            "occurred_at": snapshot.observed_at,
        }
        if prior_state in _ANSWERING and snapshot.state in _SILENT:
            events.append(
                UsageHookEvent(
                    "provider_unavailable",
                    snapshot.provider_id,
                    "",
                    snapshot.state.name.lower(),
                    **common,
                )
            )
        elif prior_state in _SILENT and snapshot.state in _ANSWERING:
            events.append(
                UsageHookEvent(
                    "provider_recovered",
                    snapshot.provider_id,
                    "",
                    snapshot.state.name.lower(),
                    **common,
                )
            )
        if snapshot.state in _FAILED and snapshot.observed_at > prior_snapshot.observed_at:
            events.append(
                UsageHookEvent(
                    "refresh_failed",
                    snapshot.provider_id,
                    "",
                    snapshot.reason_code or snapshot.state.name.lower(),
                    **common,
                )
            )
    return tuple(events)


# --- Rules -----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class UsageHookRule:
    id: str
    enabled: bool
    event: str
    provider: str | None
    threshold_remaining: float | None
    executable: str
    arguments: tuple[str, ...]
    timeout_seconds: float
    argv: str

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> UsageHookRule:
        return cls(
            id=str(raw["id"]),
            enabled=bool(raw["enabled"]),
            event=str(raw["event"]),
            provider=raw.get("provider"),
            threshold_remaining=raw.get("threshold_remaining"),
            executable=str(raw["executable"]),
            arguments=tuple(raw.get("arguments") or ()),
            timeout_seconds=float(raw["timeout_seconds"]),
            argv=str(raw["argv"]),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "enabled": self.enabled,
            "event": self.event,
            "provider": self.provider,
            "threshold_remaining": self.threshold_remaining,
            "executable": self.executable,
            "arguments": list(self.arguments),
            "timeout_seconds": self.timeout_seconds,
            "argv": self.argv,
        }

    def matches(self, event: UsageHookEvent) -> bool:
        if not self.enabled:
            return False
        if self.event not in (USAGE_HOOK_ANY_EVENT, event.name):
            return False
        if (
            self.argv == "legacy"
            and self.event == USAGE_HOOK_ANY_EVENT
            and event.name not in LEGACY_EVENTS
        ):
            # A script written for the first version knows its five
            # events; the two new ones reach it only when it names them.
            return False
        if self.provider is not None and self.provider != event.provider_id:
            return False
        if self.threshold_remaining is not None:
            if event.remaining_percent is None or event.remaining_percent > self.threshold_remaining:
                return False
        return True


def _too_long(text: str) -> bool:
    return len(text.encode("utf-8")) > MAX_STRING_BYTES


def rule_problem(rule: UsageHookRule) -> str | None:
    """Why this rule will never run, in words; None when it can."""
    if rule.event != USAGE_HOOK_ANY_EVENT and rule.event not in USAGE_HOOK_EVENTS:
        return f"unknown event {rule.event!r}"
    if not rule.executable:
        return "no executable"
    if not os.path.isabs(rule.executable):
        return "the executable must be an absolute path"
    if len(rule.arguments) > MAX_ARGUMENTS:
        return f"more than {MAX_ARGUMENTS} arguments"
    if any(_too_long(text) for text in (rule.executable, *rule.arguments)):
        return "a string is over 4 KiB"
    return None


@dataclass(frozen=True, slots=True)
class UsageHookConfig:
    enabled: bool
    rules: tuple[UsageHookRule, ...]
    #: Set when the whole configuration is refused (fail closed).
    problem: str | None = None

    def runnable(self) -> tuple[UsageHookRule, ...]:
        if not self.enabled or self.problem is not None:
            return ()
        return tuple(rule for rule in self.rules if rule.enabled and rule_problem(rule) is None)


def load_usage_hook_config(raw: object, *, legacy_path: str = "") -> UsageHookConfig:
    """The rules as the runner sees them, from ``settings.usage_hooks``."""
    hooks = normalize_usage_hooks(raw, legacy_path=legacy_path)
    rules = tuple(UsageHookRule.from_dict(item) for item in hooks["rules"])
    problem = f"more than {MAX_RULES} rules: none will run" if len(rules) > MAX_RULES else None
    return UsageHookConfig(bool(hooks["enabled"]), rules, problem)


def config_for_settings(settings: object) -> UsageHookConfig:
    return load_usage_hook_config(
        getattr(settings, "usage_hooks", None),
        legacy_path=str(getattr(settings, "usage_event_hook_path", "") or ""),
    )


# --- Limiter ---------------------------------------------------------------


class UsageHookLimiter:
    """One run per ``interval`` for each rule, event, provider, account and
    lane, for the chatty events (``THROTTLED_EVENTS``)."""

    def __init__(self, interval: float = HOOK_THROTTLE_SECONDS) -> None:
        self.interval = float(interval)
        self._lock = threading.Lock()
        self._last: dict[tuple[str, str, str, str, str], float] = {}

    def admit(self, rule: UsageHookRule, event: UsageHookEvent, now: float) -> bool:
        if event.name not in THROTTLED_EVENTS:
            return True
        key = (rule.id, event.name, event.provider_id, event.source_instance_id, event.lane_id)
        with self._lock:
            last = self._last.get(key)
            if last is not None and now - last < self.interval:
                return False
            self._last[key] = now
            if len(self._last) > 4096:
                oldest = sorted(self._last.items(), key=lambda item: item[1])[:1024]
                for stale, _at in oldest:
                    self._last.pop(stale, None)
            return True


# --- Running ---------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class UsageHookResult:
    rule_id: str
    event: str
    provider: str
    at: float
    outcome: str  # ok | exit | timeout | refused | error
    exit_code: int | None = None
    duration_seconds: float | None = None
    detail: str | None = None

    def to_dict(self) -> dict[str, Any]:
        document = {
            "rule": self.rule_id,
            "event": self.event,
            "provider": self.provider,
            "at": round(self.at, 3),
            "outcome": self.outcome,
            "exit_code": self.exit_code,
            "duration_seconds": None if self.duration_seconds is None else round(self.duration_seconds, 3),
            "detail": self.detail,
        }
        return {key: value for key, value in document.items() if value is not None}

    def sentence(self) -> str:
        """The last-result line Settings and the CLI show."""
        took = "" if self.duration_seconds is None else f" in {self.duration_seconds:.1f} s"
        if self.outcome == "ok":
            return f"{self.event}: exit 0{took}"
        if self.outcome == "exit":
            return f"{self.event}: exit {self.exit_code}{took}"
        if self.outcome == "timeout":
            return f"{self.event}: stopped after {self.duration_seconds or 0:.0f} s (timed out)"
        return f"{self.event}: {self.detail or self.outcome}"


class UsageHookResults:
    """The last result per rule, for Settings, the CLI and the Test button."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._by_rule: dict[str, UsageHookResult] = {}

    def record(self, result: UsageHookResult) -> None:
        with self._lock:
            self._by_rule[result.rule_id] = result

    def get(self, rule_id: str) -> UsageHookResult | None:
        with self._lock:
            return self._by_rule.get(rule_id)

    def snapshot(self) -> dict[str, UsageHookResult]:
        with self._lock:
            return dict(self._by_rule)


SHARED_LIMITER = UsageHookLimiter()
SHARED_RESULTS = UsageHookResults()


def hook_environment(event: UsageHookEvent, source: Mapping[str, str] | None = None) -> dict[str, str]:
    """The allowlisted environment plus the event's ``JRBAR_*`` variables."""
    parent = os.environ if source is None else source
    env = {name: parent[name] for name in ENVIRONMENT_ALLOWLIST if name in parent}
    env.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    values = {
        "JRBAR_EVENT": event.name,
        "JRBAR_PROVIDER": event.provider_id,
        "JRBAR_INSTANCE": event.source_instance_id,
        "JRBAR_LANE": event.lane_id or None,
        "JRBAR_REMAINING_PERCENT": None if event.remaining_percent is None else f"{event.remaining_percent:.2f}",
        "JRBAR_RESET_AT": None if event.reset_at is None else f"{event.reset_at:.0f}",
        "JRBAR_STATE": event.state,
        "JRBAR_TIMESTAMP": f"{(event.occurred_at or time.time()):.0f}",
    }
    env.update({key: value for key, value in values.items() if value})
    return env


def hook_argv(rule: UsageHookRule, event: UsageHookEvent) -> list[str]:
    if rule.argv == "legacy":
        return [rule.executable, event.name, event.provider_id, event.lane_id, event.detail]
    return [rule.executable, *rule.arguments]


def run_rule(
    rule: UsageHookRule,
    event: UsageHookEvent,
    *,
    environ: Mapping[str, str] | None = None,
    timeout: float | None = None,
    clock: Callable[[], float] = time.time,
) -> UsageHookResult:
    """Run one rule for one event, synchronously, and say what happened."""
    started = clock()
    problem = rule_problem(rule)
    if problem is not None:
        return UsageHookResult(rule.id, event.name, event.provider_id, started, "refused", detail=problem)
    payload = encode_payload(event, now=started)
    if len(payload) > MAX_PAYLOAD_BYTES:
        return UsageHookResult(
            rule.id, event.name, event.provider_id, started, "refused", detail="event JSON over 4 KiB"
        )
    limit = rule.timeout_seconds if timeout is None else min(rule.timeout_seconds, timeout)
    monotonic_start = time.monotonic()
    try:
        process = subprocess.Popen(
            hook_argv(rule, event),
            stdin=subprocess.PIPE if rule.argv != "legacy" else subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=hook_environment(event, environ),
            close_fds=True,
            start_new_session=True,
        )
    except (OSError, ValueError) as error:
        return UsageHookResult(
            rule.id, event.name, event.provider_id, started, "error", detail=f"could not start: {error.strerror or error}"
        )
    try:
        process.communicate(input=payload if rule.argv != "legacy" else None, timeout=limit)
    except subprocess.TimeoutExpired:
        _kill(process)
        return UsageHookResult(
            rule.id,
            event.name,
            event.provider_id,
            started,
            "timeout",
            duration_seconds=time.monotonic() - monotonic_start,
            detail="timed out",
        )
    except OSError as error:
        _kill(process)
        return UsageHookResult(rule.id, event.name, event.provider_id, started, "error", detail=str(error))
    code = process.returncode
    return UsageHookResult(
        rule.id,
        event.name,
        event.provider_id,
        started,
        "ok" if code == 0 else "exit",
        exit_code=code,
        duration_seconds=time.monotonic() - monotonic_start,
    )


def _kill(process: subprocess.Popen) -> None:
    """Kill the hook and anything it started (its own process group)."""
    try:
        os.killpg(process.pid, 9)
    except OSError:
        try:
            process.kill()
        except OSError:
            pass
    try:
        process.wait(timeout=2.0)
    except (subprocess.TimeoutExpired, OSError):
        pass


def _log(message: str) -> None:
    try:
        from .status_bar import log_status_bar

        log_status_bar(message)
    except Exception:
        print(message, flush=True)


def dispatch_usage_hooks(
    config: UsageHookConfig,
    events: Iterable[UsageHookEvent],
    *,
    limiter: UsageHookLimiter = SHARED_LIMITER,
    results: UsageHookResults = SHARED_RESULTS,
    environ: Mapping[str, str] | None = None,
    clock: Callable[[], float] = time.time,
    log: Callable[[str], None] = _log,
) -> threading.Thread | None:
    """Match events to rules, apply the limiter, and run the batch on one
    background thread. Returns the thread, or None when nothing runs."""
    if config.problem is not None and config.enabled:
        log(f"usage hooks: {config.problem}")
        return None
    rules = config.runnable()
    if not rules:
        return None
    now = clock()
    work: list[tuple[UsageHookRule, UsageHookEvent]] = [
        (rule, event)
        for event in events
        for rule in rules
        if rule.matches(event) and limiter.admit(rule, event, now)
    ]
    if not work:
        return None
    snapshot_env = dict(os.environ if environ is None else environ)

    def _run() -> None:
        for rule, event in work:
            result = run_rule(rule, event, environ=snapshot_env, clock=clock)
            results.record(result)
            if result.outcome != "ok":
                # A typo'd path used to fail forever in total silence; the
                # log is the minimum honesty a fire-and-forget hook owes.
                log(f"usage hook {rule.id}: {result.sentence()}")

    worker = threading.Thread(target=_run, name="JRBarUsageHooks", daemon=True)
    worker.start()
    return worker


def sample_event(event_name: str, provider_id: str, *, now: float | None = None) -> UsageHookEvent:
    """A made-up event for ``jrbar usage-hooks test`` and the Test button:
    plausible numbers, marked ``state: test`` so a script can tell."""
    moment = time.time() if now is None else now
    remaining = {"quota_low": 18.0, "quota_reached": 0.0, "quota_reset": 100.0}.get(event_name, 57.0)
    lane = "" if event_name in {"provider_unavailable", "provider_recovered", "refresh_failed"} else "five-hour"
    return UsageHookEvent(
        event_name,
        provider_id,
        lane,
        f"{remaining:.0f}" if lane else "test",
        remaining_percent=remaining if lane else None,
        reset_at=moment + 3 * 3600 if lane else None,
        state="test",
        event_id="test" if event_name == "quota_reset" else None,
        label="5-hour" if lane else None,
        occurred_at=moment,
    )


# --- The first version's save message, kept for the legacy settings window --


def hook_path_message(hook_path: str) -> str:
    """Save confirmation that never lies about a path that can't run."""
    if not hook_path:
        return "Usage event hook off."
    hook_path = os.path.expanduser(hook_path)
    if not os.path.exists(hook_path):
        return "Saved, but that path does not exist — the hook will never fire."
    if not os.access(hook_path, os.X_OK):
        return "Saved, but that file is not executable (chmod +x it)."
    return "Usage event hook saved."


__all__ = [
    "ENVIRONMENT_ALLOWLIST",
    "HOOK_THROTTLE_SECONDS",
    "HOOK_TIMEOUT_SECONDS",
    "MAX_ARGUMENTS",
    "MAX_PAYLOAD_BYTES",
    "MAX_RULES",
    "SHARED_RESULTS",
    "THROTTLED_EVENTS",
    "UsageHookConfig",
    "UsageHookEvent",
    "UsageHookLimiter",
    "UsageHookResult",
    "UsageHookResults",
    "UsageHookRule",
    "config_for_settings",
    "detect_usage_hook_events",
    "dispatch_usage_hooks",
    "encode_payload",
    "hook_argv",
    "hook_environment",
    "hook_path_message",
    "load_usage_hook_config",
    "rule_problem",
    "run_rule",
    "sample_event",
]
