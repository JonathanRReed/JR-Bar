"""AppKit-free lifecycle authority for the current DND projection."""

from __future__ import annotations

import math
import threading
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from enum import Enum
from itertools import islice
from typing import Protocol

from .dnd_policy import (
    DisplayAdmission,
    DndContribution,
    DndMode,
    DndOverride,
    DndProjection,
    DndSchedule,
    DndSource,
    OutboundAdmission,
    compose_dnd_contributions,
    contribution_for_presence,
    evaluate_dnd_policy,
)
from .focus_status import (
    FocusActivity,
    FocusAuthorization,
    FocusStatusObservation,
    MacOSFocusStatusClient,
)
from .local_time_boundary import system_local_timezone
from .settings import SettingsConcurrentWriteError, SettingsWriteRefusedError

MAX_NAMED_FOCUS_IDENTIFIERS = 16
MAX_NAMED_FOCUS_IDENTIFIER_LENGTH = 256


class _TimerLike(Protocol):
    def start(self) -> None: ...

    def cancel(self) -> None: ...


class _FocusClient(Protocol):
    # A client may also offer ``invalidate()`` to drop cached reads; the
    # controller calls it where the system state can have moved under it.
    def observe(self) -> FocusStatusObservation: ...

    def request_authorization(
        self,
        completion: Callable[[FocusAuthorization], None],
    ) -> bool: ...


class DndChangeFailure(str, Enum):
    CLOSED = "closed"
    NOT_STARTED = "not_started"
    SAVE_IN_PROGRESS = "save_in_progress"
    CONCURRENT_WRITE = "concurrent_write"
    WRITE_REFUSED = "write_refused"
    STALE_CALLBACK = "stale_callback"
    STALE_SAVE = "stale_save"


@dataclass(frozen=True, slots=True)
class DndChangeResult:
    applied: bool
    projection: DndProjection
    failure: DndChangeFailure | None = None

    def __post_init__(self) -> None:
        if type(self.applied) is not bool:
            raise TypeError("DND change application must be a boolean")
        if type(self.projection) is not DndProjection:
            raise TypeError("DND change projection must be canonical")
        if self.failure is not None and type(self.failure) is not DndChangeFailure:
            raise TypeError("DND change failure must be typed")
        if self.applied == (self.failure is not None):
            raise ValueError("DND change result application and failure disagree")


def _default_timer_factory(
    delay: float,
    callback: Callable[[], None],
) -> _TimerLike:
    timer = threading.Timer(delay, callback)
    timer.daemon = True
    return timer


class DndController:
    """Own one durable projection, one deadline, and all callback fences."""

    def __init__(
        self,
        *,
        settings_getter: Callable[[], object],
        settings_setter: Callable[[object], None],
        settings_saver: Callable[[object], None],
        on_projection: Callable[[DndProjection], None],
        focus_client: _FocusClient | None = None,
        named_focus_reader: Callable[[], Iterable[str]] | None = None,
        wall_clock: Callable[[], float] = time.time,
        timezone_getter: Callable[[float], object] = system_local_timezone,
        timer_factory: Callable[[float, Callable[[], None]], _TimerLike]
        | None = None,
        recovery_timer_factory: Callable[[float, Callable[[], None]], _TimerLike]
        | None = None,
    ) -> None:
        dependencies = (
            settings_getter,
            settings_setter,
            settings_saver,
            on_projection,
            wall_clock,
            timezone_getter,
        )
        if not all(callable(dependency) for dependency in dependencies):
            raise ValueError("invalid DND controller dependency")
        if named_focus_reader is not None and not callable(named_focus_reader):
            raise ValueError("invalid named Focus reader")
        if timer_factory is not None and not callable(timer_factory):
            raise ValueError("invalid DND timer factory")
        if recovery_timer_factory is not None and not callable(
            recovery_timer_factory
        ):
            raise ValueError("invalid DND recovery timer factory")
        effective_focus: _FocusClient = (
            MacOSFocusStatusClient() if focus_client is None else focus_client
        )
        if not (
            callable(getattr(effective_focus, "observe", None))
            and callable(getattr(effective_focus, "request_authorization", None))
        ):
            raise ValueError("invalid public Focus client")

        self._settings_getter = settings_getter
        self._settings_setter = settings_setter
        self._settings_saver = settings_saver
        self._on_projection = on_projection
        self._focus_client = effective_focus
        self._named_focus_reader = named_focus_reader
        self._wall_clock = wall_clock
        self._timezone_getter = timezone_getter
        self._timer_factory = timer_factory or _default_timer_factory
        self._recovery_timer_factory = (
            recovery_timer_factory or _default_timer_factory
        )

        self._projection = compose_dnd_contributions(())
        self._focus_observation = FocusStatusObservation(
            FocusAuthorization.UNAVAILABLE,
            FocusActivity.UNAVAILABLE,
        )
        self._named_focus_identifiers: tuple[str, ...] = ()
        self._timer: _TimerLike | None = None
        self._transition_deadline: float | None = None
        self._local_timezone: object | None = None
        self._generation = 0
        self._authorization_generation = 0
        self._save_generation = 0
        self._save_in_progress = False
        self._refresh_deferred = False
        self._started = False
        self._closed = False
        # The app's presence report (jrbar.presence.PresenceFacts): a call,
        # a meeting, and its own Focus reading. None until one arrives.
        self._presence: object | None = None

    @property
    def projection(self) -> DndProjection:
        return self._projection

    @property
    def presence(self) -> object | None:
        return self._presence

    def set_presence(self, facts: object | None) -> DndChangeResult:
        """Adopt the app's latest presence report and re-evaluate. A call
        or meeting contributes its own quiet source; the app's Focus reading
        stands in for the daemon's when the daemon cannot read Focus."""
        self._presence = facts
        if self._closed:
            return self._result(False, DndChangeFailure.CLOSED)
        if not self._started:
            return self._result(False, DndChangeFailure.NOT_STARTED)
        return self.refresh()

    def _focus_hint(self, now: float) -> bool | None:
        facts = self._presence
        hint = getattr(facts, "focus_hint", None)
        if not callable(hint):
            return None
        try:
            value = hint(now)
        except Exception:
            return None
        return value if isinstance(value, bool) else None

    def _public_focus_active(
        self,
        settings: object,
        observation: FocusStatusObservation,
        now: float,
    ) -> bool:
        if not bool(getattr(settings, "focus_sync_enabled", False)):
            return False
        if observation.authorization is FocusAuthorization.AUTHORIZED:
            return observation.activity is FocusActivity.ACTIVE
        # The daemon's helper holds no Focus Status grant of its own; the
        # app does, and says what it reads. Only a positive reading counts,
        # and only while the report is fresh.
        return self._focus_hint(now) is True

    def _presence_contributions(
        self,
        settings: object,
        now: float,
        dim_fraction: float,
    ) -> tuple[DndContribution | None, DndContribution | None, tuple[float, ...]]:
        facts = self._presence
        if facts is None:
            return None, None, ()
        from .presence import (
            DEFAULT_CALL_QUIET_MODE,
            DEFAULT_MEETING_QUIET_MODE,
            normalize_presence_quiet_mode,
        )

        call = meeting = None
        transitions: tuple[float, ...] = ()
        try:
            if facts.on_call(now):  # type: ignore[attr-defined]
                call = contribution_for_presence(
                    DndSource.CALL,
                    normalize_presence_quiet_mode(
                        getattr(settings, "call_quiet_mode", DEFAULT_CALL_QUIET_MODE),
                        DEFAULT_CALL_QUIET_MODE,
                    ),
                    dim_fraction=dim_fraction,
                )
            if facts.in_meeting(now):  # type: ignore[attr-defined]
                meeting = contribution_for_presence(
                    DndSource.CALENDAR,
                    normalize_presence_quiet_mode(
                        getattr(settings, "meeting_quiet_mode", DEFAULT_MEETING_QUIET_MODE),
                        DEFAULT_MEETING_QUIET_MODE,
                    ),
                    dim_fraction=dim_fraction,
                )
                until = getattr(facts, "meeting_until", None)
                if meeting is not None and until is not None:
                    transitions = (float(until),)
        except (AttributeError, TypeError, ValueError):
            return None, None, ()
        return call, meeting, transitions

    @property
    def focus_observation(self) -> FocusStatusObservation:
        return self._focus_observation

    @property
    def named_focus_identifiers(self) -> tuple[str, ...]:
        return self._named_focus_identifiers

    @property
    def transition_deadline(self) -> float | None:
        return self._transition_deadline

    @property
    def generation(self) -> int:
        return self._generation

    @property
    def started(self) -> bool:
        return self._started

    @property
    def closed(self) -> bool:
        return self._closed

    def _result(
        self,
        applied: bool,
        failure: DndChangeFailure | None = None,
    ) -> DndChangeResult:
        return DndChangeResult(applied, self._projection, failure)

    def start(self) -> DndChangeResult:
        if self._closed:
            return self._result(False, DndChangeFailure.CLOSED)
        if self._started:
            return self._result(True)
        self._started = True
        try:
            return self.refresh()
        except Exception:
            self._started = False
            raise

    def refresh(self) -> DndChangeResult:
        if self._closed:
            return self._result(False, DndChangeFailure.CLOSED)
        if not self._started:
            return self._result(False, DndChangeFailure.NOT_STARTED)
        if self._save_in_progress:
            self._refresh_deferred = True
            return self._result(False, DndChangeFailure.SAVE_IN_PROGRESS)
        generation = self._generation
        try:
            observation = self._focus_client.observe()
        except Exception:
            observation = FocusStatusObservation(
                FocusAuthorization.UNAVAILABLE,
                FocusActivity.UNAVAILABLE,
            )
        if type(observation) is not FocusStatusObservation:
            observation = FocusStatusObservation(
                FocusAuthorization.UNAVAILABLE,
                FocusActivity.UNAVAILABLE,
            )
        settings = self._settings_getter()
        named = ()
        if self._public_focus_active(settings, observation, self._finite_now()):
            named = self._read_named_focus_identifiers()
        if not self._accept_focus_observation(generation, observation, named):
            return self._result(False, DndChangeFailure.STALE_CALLBACK)
        return self._result(True)

    def _read_named_focus_identifiers(self) -> tuple[str, ...]:
        reader = self._named_focus_reader
        if reader is None:
            return ()
        try:
            raw = reader()
            if isinstance(raw, (str, bytes)):
                return ()
            values = tuple(islice(iter(raw), MAX_NAMED_FOCUS_IDENTIFIERS + 1))
        except Exception:
            return ()
        if len(values) > MAX_NAMED_FOCUS_IDENTIFIERS:
            return ()
        identifiers = {
            value.strip()
            for value in values
            if type(value) is str
            and value.strip()
            and len(value.strip()) <= MAX_NAMED_FOCUS_IDENTIFIER_LENGTH
        }
        return tuple(sorted(identifiers))

    def _accept_focus_observation(
        self,
        generation: int,
        observation: FocusStatusObservation,
        named_focus_identifiers: Iterable[str] = (),
    ) -> bool:
        """Apply one exact observation only while its refresh is current."""
        if (
            self._closed
            or not self._started
            or type(generation) is not int
            or generation != self._generation
            or type(observation) is not FocusStatusObservation
        ):
            return False
        named = self._normalize_injected_identifiers(named_focus_identifiers)
        settings = self._settings_getter()
        now = self._finite_now()
        local_timezone = self._timezone_getter(now)
        public_active = self._public_focus_active(settings, observation, now)
        if not public_active:
            named = ()
        named_contribution = (
            self._named_focus_contribution(settings, named)
            if public_active and named
            else None
        )
        parsed = settings.dnd_settings()
        call, meeting, presence_transitions = self._presence_contributions(
            settings, now, parsed.dim_fraction
        )
        projection = evaluate_dnd_policy(
            schedule=parsed.schedule,
            override=parsed.override,
            dim_fraction=parsed.dim_fraction,
            focus_mode=parsed.focus_mode,
            now=now,
            local_timezone=local_timezone,
            macos_focus_active=public_active,
            named_focus=named_contribution,
            call=call,
            meeting=meeting,
            extra_transitions=presence_transitions,
        )
        next_generation = generation + 1
        prepared_timer = self._prepare_timer(
            projection.next_transition_epoch,
            next_generation,
            now,
            timer_factory=self._timer_factory,
        )
        if (
            self._closed
            or self._save_in_progress
            or generation != self._generation
        ):
            self._cancel_specific_timer(prepared_timer)
            return False
        return self._commit_projection(
            expected_generation=generation,
            next_generation=next_generation,
            observation=observation,
            named=named,
            projection=projection,
            prepared_timer=prepared_timer,
            local_timezone=local_timezone,
        )

    @staticmethod
    def _normalize_injected_identifiers(values: Iterable[str]) -> tuple[str, ...]:
        try:
            if isinstance(values, (str, bytes)):
                return ()
            sampled = tuple(islice(iter(values), MAX_NAMED_FOCUS_IDENTIFIERS + 1))
        except Exception:
            return ()
        if len(sampled) > MAX_NAMED_FOCUS_IDENTIFIERS:
            return ()
        return tuple(
            sorted(
                {
                    value.strip()
                    for value in sampled
                    if type(value) is str
                    and value.strip()
                    and len(value.strip()) <= MAX_NAMED_FOCUS_IDENTIFIER_LENGTH
                }
            )
        )

    @staticmethod
    def _named_focus_contribution(
        settings: object,
        identifiers: tuple[str, ...],
    ) -> DndContribution | None:
        dim_for = getattr(settings, "focus_dim_fraction", None)
        if not identifiers or not callable(dim_for):
            return None
        factors: list[float] = []
        for identifier in identifiers:
            try:
                factor = float(dim_for(identifier))
            except (OverflowError, TypeError, ValueError):
                continue
            if math.isfinite(factor) and 0.0 <= factor <= 1.0:
                factors.append(factor)
        if not factors:
            return None
        raw_policies = getattr(settings, "focus_signal_policy", {})
        policies = raw_policies if type(raw_policies) is dict else {}
        asks_only = any(policies.get(identifier) == "asks_only" for identifier in identifiers)
        silent = any(policies.get(identifier) == "silent" for identifier in identifiers)
        return DndContribution(
            DndSource.NAMED_FOCUS,
            None,
            DisplayAdmission.ASKS if asks_only else DisplayAdmission.ALL,
            min(factors),
            OutboundAdmission.ASKS if asks_only else OutboundAdmission.ALL,
            True,
            not silent,
            True,
        )

    def _finite_now(self) -> float:
        raw = self._wall_clock()
        if isinstance(raw, bool) or not isinstance(raw, (int, float)):
            raise RuntimeError("DND wall clock returned an invalid value")
        now = float(raw)
        if not math.isfinite(now):
            raise RuntimeError("DND wall clock returned an invalid value")
        return now

    def _prepare_timer(
        self,
        deadline: float | None,
        generation: int,
        now: float,
        *,
        timer_factory: Callable[[float, Callable[[], None]], _TimerLike],
    ) -> _TimerLike | None:
        if deadline is None:
            return None
        delay = max(0.0, deadline - now)
        timer = timer_factory(
            delay,
            lambda: self._transition_timer_fired(generation, deadline),
        )
        if not (
            callable(getattr(timer, "start", None))
            and callable(getattr(timer, "cancel", None))
        ):
            raise RuntimeError("DND timer factory returned an invalid timer")
        return timer

    def _commit_projection(
        self,
        *,
        expected_generation: int,
        next_generation: int,
        observation: FocusStatusObservation,
        named: tuple[str, ...],
        projection: DndProjection,
        prepared_timer: _TimerLike | None,
        local_timezone: object,
    ) -> bool:
        if (
            self._closed
            or self._save_in_progress
            or self._generation != expected_generation
        ):
            self._cancel_specific_timer(prepared_timer)
            return False
        previous_generation = self._generation
        previous_observation = self._focus_observation
        previous_named = self._named_focus_identifiers
        previous_projection = self._projection
        previous_timer = self._timer
        previous_deadline = self._transition_deadline
        previous_timezone = self._local_timezone

        self._generation = next_generation
        self._focus_observation = observation
        self._named_focus_identifiers = named
        self._projection = projection
        self._timer = prepared_timer
        self._transition_deadline = projection.next_transition_epoch
        self._local_timezone = local_timezone
        try:
            if prepared_timer is not None:
                prepared_timer.start()
        except Exception:
            self._generation = previous_generation
            self._focus_observation = previous_observation
            self._named_focus_identifiers = previous_named
            self._projection = previous_projection
            self._timer = previous_timer
            self._transition_deadline = previous_deadline
            self._local_timezone = previous_timezone
            self._cancel_specific_timer(prepared_timer)
            raise
        if (
            self._generation != next_generation
            or self._timer is not prepared_timer
        ):
            self._cancel_specific_timer(previous_timer)
            return not self._closed
        self._cancel_specific_timer(previous_timer)
        self._on_projection(projection)
        return True

    def _transition_timer_fired(self, generation: int, deadline: float) -> None:
        if (
            self._closed
            or generation != self._generation
            or deadline != self._transition_deadline
        ):
            return
        if self._save_in_progress:
            self._refresh_deferred = True
            return
        self._cancel_timer()
        self.refresh()

    def _cancel_timer(self) -> None:
        timer = self._timer
        self._timer = None
        self._transition_deadline = None
        self._cancel_specific_timer(timer)

    @staticmethod
    def _cancel_specific_timer(timer: _TimerLike | None) -> None:
        if timer is not None:
            try:
                timer.cancel()
            except Exception:
                pass

    def _persist_candidate(self, candidate: object) -> DndChangeResult:
        if self._closed:
            return self._result(False, DndChangeFailure.CLOSED)
        if not self._started:
            return self._result(False, DndChangeFailure.NOT_STARTED)
        if self._save_in_progress:
            return self._result(False, DndChangeFailure.SAVE_IN_PROGRESS)
        self._save_generation += 1
        save_generation = self._save_generation
        self._save_in_progress = True
        try:
            self._settings_saver(candidate)
        except SettingsConcurrentWriteError:
            return self._finish_refused_save(DndChangeFailure.CONCURRENT_WRITE)
        except SettingsWriteRefusedError:
            return self._finish_refused_save(DndChangeFailure.WRITE_REFUSED)
        except Exception:
            self._save_in_progress = False
            self._drain_deferred_refresh()
            raise
        if self._closed or save_generation != self._save_generation:
            self._save_in_progress = False
            self._refresh_deferred = False
            return self._result(False, DndChangeFailure.STALE_SAVE)
        self._settings_setter(candidate)
        self._save_in_progress = False
        self._refresh_deferred = False
        return self.refresh()

    def _finish_refused_save(
        self,
        failure: DndChangeFailure,
    ) -> DndChangeResult:
        self._save_in_progress = False
        self._drain_deferred_refresh()
        return self._result(False, failure)

    def _drain_deferred_refresh(self) -> None:
        if not self._refresh_deferred:
            return
        self._refresh_deferred = False
        if self._closed or not self._started:
            return
        try:
            refreshed = self.refresh()
        except Exception:
            self._recover_deferred_refresh()
            return
        if not refreshed.applied:
            self._recover_deferred_refresh()

    def _recover_deferred_refresh(self) -> None:
        """Recover an expired timer without replacing the save refusal."""
        if self._closed or not self._started:
            return
        local_timezone = self._local_timezone
        if local_timezone is None:
            self._cohere_without_transition()
            return
        try:
            settings = self._settings_getter()
            now = self._finite_now()
            observation = self._focus_observation
            named = self._named_focus_identifiers
            public_active = self._public_focus_active(settings, observation, now)
            if not public_active:
                named = ()
            named_contribution = (
                self._named_focus_contribution(settings, named)
                if public_active and named
                else None
            )
            parsed = settings.dnd_settings()
            call, meeting, presence_transitions = self._presence_contributions(
                settings, now, parsed.dim_fraction
            )
            projection = evaluate_dnd_policy(
                schedule=parsed.schedule,
                override=parsed.override,
                dim_fraction=parsed.dim_fraction,
                focus_mode=parsed.focus_mode,
                now=now,
                local_timezone=local_timezone,
                macos_focus_active=public_active,
                named_focus=named_contribution,
                call=call,
                meeting=meeting,
                extra_transitions=presence_transitions,
            )
            expected_generation = self._generation
            next_generation = expected_generation + 1
            prepared_timer = self._prepare_timer(
                projection.next_transition_epoch,
                next_generation,
                now,
                timer_factory=self._recovery_timer_factory,
            )
            recovered = self._commit_projection(
                expected_generation=expected_generation,
                next_generation=next_generation,
                observation=observation,
                named=named,
                projection=projection,
                prepared_timer=prepared_timer,
                local_timezone=local_timezone,
            )
        except Exception:
            self._cohere_without_transition()
            return
        if not recovered:
            self._cohere_without_transition()

    def _cohere_without_transition(self) -> None:
        """Fail closed when neither primary nor recovery timing can be armed."""
        if self._closed:
            return
        projection = compose_dnd_contributions(
            self._projection.contributions,
            next_transition_epoch=None,
        )
        self._cancel_timer()
        self._generation += 1
        self._projection = projection
        try:
            self._on_projection(projection)
        except Exception:
            pass

    def set_schedule(self, schedule: DndSchedule) -> DndChangeResult:
        if type(schedule) is not DndSchedule:
            raise ValueError("DND schedule edit must be canonical")
        settings = self._settings_getter()
        candidate = settings.with_dnd_schedule(
            enabled=schedule.enabled,
            start_minutes=schedule.start_minutes,
            end_minutes=schedule.end_minutes,
            mode=schedule.mode,
        )
        return self._persist_candidate(candidate)

    def set_dim_fraction(self, fraction: float) -> DndChangeResult:
        settings = self._settings_getter()
        candidate = settings.with_dnd_dim_fraction(fraction)
        return self._persist_candidate(candidate)

    def set_follow_focus(self, enabled: bool) -> DndChangeResult:
        if type(enabled) is not bool:
            raise ValueError("Follow Focus edit must be a boolean")
        settings = self._settings_getter()
        candidate = settings.with_focus_sync_enabled(enabled)
        return self._persist_candidate(candidate)

    def set_focus_mode(self, mode: DndMode) -> DndChangeResult:
        if type(mode) is not DndMode:
            raise ValueError("DND Focus mode edit must be canonical")
        settings = self._settings_getter()
        candidate = settings.with_dnd_focus_mode(mode)
        return self._persist_candidate(candidate)

    def set_override(self, override: DndOverride | None) -> DndChangeResult:
        if override is not None and type(override) is not DndOverride:
            raise ValueError("DND override edit must be canonical")
        settings = self._settings_getter()
        candidate = settings.with_dnd_override(override)
        return self._persist_candidate(candidate)

    def request_focus_authorization(self) -> bool:
        """Reach the system prompt only from an explicit Settings action."""
        if self._closed or not self._started:
            return False
        self._authorization_generation += 1
        generation = self._authorization_generation

        def completed(authorization: FocusAuthorization) -> None:
            self._authorization_completed(generation, authorization)

        try:
            started = self._focus_client.request_authorization(completed)
        except Exception:
            started = False
        if type(started) is not bool or not started:
            self._authorization_generation += 1
            return False
        return True

    def _authorization_completed(
        self,
        generation: int,
        authorization: FocusAuthorization,
    ) -> None:
        if (
            self._closed
            or generation != self._authorization_generation
            or type(authorization) is not FocusAuthorization
        ):
            return
        self._focus_observation = FocusStatusObservation(
            authorization,
            FocusActivity.UNAVAILABLE,
        )
        self._invalidate_focus_reads()
        self.refresh()

    def _invalidate_focus_reads(self) -> None:
        """Make the next refresh ask the system, not the client's cache: a
        wake or an activation is where a Focus or permission change made
        elsewhere shows up."""
        invalidate = getattr(self._focus_client, "invalidate", None)
        if callable(invalidate):
            try:
                invalidate()
            except Exception:
                pass

    def handle_wake(self) -> DndChangeResult:
        self._invalidate_focus_reads()
        return self.refresh()

    def handle_sleep(self) -> DndChangeResult:
        return self.refresh()

    def handle_screen_wake(self) -> DndChangeResult:
        self._invalidate_focus_reads()
        return self.refresh()

    def handle_screen_sleep(self) -> DndChangeResult:
        return self.refresh()

    def handle_activation(self) -> DndChangeResult:
        self._invalidate_focus_reads()
        return self.refresh()

    def handle_clock_change(self) -> DndChangeResult:
        return self.refresh()

    def handle_timezone_change(self) -> DndChangeResult:
        return self.refresh()

    def handle_environment_refresh(self) -> DndChangeResult:
        return self.refresh()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self._started = False
        self._generation += 1
        self._authorization_generation += 1
        self._save_generation += 1
        self._refresh_deferred = False
        self._cancel_timer()


__all__ = [
    "MAX_NAMED_FOCUS_IDENTIFIERS",
    "DndChangeFailure",
    "DndChangeResult",
    "DndController",
]
