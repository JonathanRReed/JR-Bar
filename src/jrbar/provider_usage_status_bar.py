"""Native-provider layer for the retained AppKit host."""

from __future__ import annotations

import time
from collections.abc import Callable
from pathlib import Path

from .provider_usage_status_bar_probe import (
    PROBE_IMPORT_MODE as _PROBE_IMPORT_MODE,
)
from .provider_usage_status_bar_probe import (
    ProbeLegacyShim as _ProbeLegacyShim,
)

if _PROBE_IMPORT_MODE:
    _legacy = _ProbeLegacyShim()
    _BaseStatusBarController = object
else:
    from . import status_bar as _host
    from .provider_credential_store import ProviderCredentialStore
    from .provider_feature_settings import (
        ProviderPresentationSettings,
        project_presentation_settings,
    )
    from .provider_reset_events import (
        ResetDeliverySettings,
        ResetDeliveryState,
        begin_reset_delivery,
        next_reset_retry_delay,
        reset_event_is_terminal,
        with_reset_candidates,
    )
    from .provider_reset_settings_action import (
        note_reset_candidates,
        reset_delivery_state,
    )
    from .provider_usage_controller_actions import (
        apply_provider_usage_settings_snapshot,
        profile_session_action,
    )
    from .provider_usage_event_store import save_reset_delivery_state
    from .provider_usage_feedback_actions import (
        alert_connection_loss,
        alert_new_critical_pace,
        celebrate_quota_resets,
        report_reconnect_outcome,
    )
    from .provider_usage_qol import (
        confirm_reset_events,
        detect_reset_events,
        merged_edge_baseline,
        threshold_crossings,
    )
    from .provider_usage_runtime import (
        ProviderUsageApply,
        ProviderUsageService,
        ProviderUsageState,
        status_feed_incident_lookup,
    )
    from .provider_usage_settings import (
        ProviderUsageSettings,
        load_provider_usage_settings,
    )
    from .provider_usage_store import load_provider_usage_state, save_provider_usage_state
    from .provider_usage_sync_cache import refresh_cached_merged_sync
    from .usage_event_hooks import (
        config_for_settings,
        detect_usage_hook_events,
        dispatch_usage_hooks,
    )
    from .usage_percent_history import record_state_observations

    _legacy = getattr(_host, "_legacy", _host)
    from .deck_status_bar import install_deck_status_bar

    _BaseStatusBarController = install_deck_status_bar(_host.JRStatusBarController)


def _publish_reset_wire_events(controller, reset_events) -> None:
    """Publish each reset as a ``quota_reset`` core event.

    The app's Usage Center re-fetches on it, and Confetti fires only on
    the weekly lane -- so ``lane`` (``weekly``, ``*-weekly``, the
    five-hour window's own id) travels on every event, and a missing
    ``_core_publish_event`` (the legacy menu host) simply publishes none.
    A single bad event must not block the rest.
    """
    publish = getattr(controller, "_core_publish_event", None)
    if not callable(publish):
        return
    for event in reset_events:
        try:
            publish(
                "quota_reset",
                provider=event.provider_id,
                instance=event.source_instance_id,
                label=event.label,
                lane=event.lane_id,
                # The same id the celebration and the usage hook carry.
                event_id=event.event_id,
            )
        except Exception:
            pass


_existing_controller = globals().get("JRProviderUsageStatusBarController")
if isinstance(_existing_controller, type) and _existing_controller.__name__ == "JRProviderUsageStatusBarController":
    JRProviderUsageStatusBarController = _existing_controller
else:

    class JRProviderUsageStatusBarController(_BaseStatusBarController):
        """Native provider usage controller."""

        @property
        def provider_usage_state(self) -> ProviderUsageState:
            return getattr(
                self,
                "_jrbar_provider_usage_state",
                ProviderUsageState((), None, None, False),
            )

        # --- Native provider usage --------------------------------------

        def _provider_usage_service(self) -> ProviderUsageService:
            service = getattr(self, "_jrbar_provider_usage_service", None)
            if type(service) is ProviderUsageService:
                return service
            from .cliproxy_hub import HubSource

            service = ProviderUsageService(
                settings_loader=load_provider_usage_settings,
                credentials=ProviderCredentialStore(),
                home=Path.home(),
                state_loader=load_provider_usage_state,
                state_saver=save_provider_usage_state,
                # The CLIProxyAPI hub's accounts (off unless cliproxy_hub
                # is enabled; loopback only, every 5 min at most).
                extra_source=HubSource(settings_loader=lambda: self.settings),
                # Provider status pages: off until Settings > Usage turns
                # them on, and read live on every refresh.
                incident_lookup=status_feed_incident_lookup(
                    settings_loader=lambda: self.settings
                ),
            )
            self._jrbar_provider_usage_service = service
            self._jrbar_provider_usage_state = service.snapshot()
            return service

        def _request_provider_usage(
            self,
            *,
            force: bool = False,
            providers: tuple[str | tuple[str, str], ...] | None = None,
        ) -> None:
            service = self._provider_usage_service()
            current = service.request(
                callback=self._provider_usage_ready,
                force=force,
                providers=providers,
            )
            self._jrbar_provider_usage_state = current

        def _provider_usage_log(self, message: str) -> None:
            _legacy.log_status_bar(message)

        def _provider_usage_ready(self, state: ProviderUsageState) -> None:
            service = self._provider_usage_service()
            settings = service.settings_snapshot()
            if settings is None:
                return
            refresh_cached_merged_sync(state)
            payload = ProviderUsageApply(
                state,
                project_presentation_settings(settings),
                settings,
            )
            try:
                self.performSelectorOnMainThread_withObject_waitUntilDone_(
                    "applyProviderUsageState:",
                    payload,
                    False,
                )
            except Exception:
                return

        @_legacy.objc.IBAction
        def applyProviderUsageState_(self, payload) -> None:
            if type(payload) is not ProviderUsageApply:
                return
            state = payload.state
            presentation = payload.settings
            if type(payload.usage_settings) is ProviderUsageSettings:
                apply_provider_usage_settings_snapshot(
                    self,
                    payload.usage_settings,
                )
            self._jrbar_provider_presentation_settings = presentation
            settings = presentation
            # The edge BASELINE is owned by this method alone. It used
            # to read _jrbar_provider_usage_state, which every 15s
            # tick overwrites with the service's current state -- so a
            # tick landing between the worker's publish and this apply
            # made previous == current and blinded EVERY edge detector
            # (resets, thresholds, pace, hooks, connection loss).
            previous_state = getattr(
                self,
                "_jrbar_provider_usage_edge_baseline",
                ProviderUsageState((), None, None, False),
            )
            # Last COMPARABLE reading per provider -- a degraded
            # (vendor-incident) publish must not wipe the pre-reset
            # baseline the detectors compare against.
            self._jrbar_provider_usage_edge_baseline = merged_edge_baseline(previous_state, state)
            self._jrbar_provider_usage_state = state
            # Percent history: every provider's "how much is left", so the
            # settings chart can show ALL of them.
            if (
                record_state_observations(
                self,
                state.snapshots,
                writer=self._persistence_writer,
                )
                is False
            ):
                self._provider_usage_log("usage percent history write not queued")
            # The saved deliveries and the jumps still waiting for
            # confirmation, loaded once for this and refresh_'s delivery
            # alike, so a restart mid-candidate neither drops nor repeats
            # a reset.
            delivery_state = reset_delivery_state(self)
            seen = {
                event.event_id
                for event in delivery_state.events
                if reset_event_is_terminal(delivery_state, event.event_id)
            }
            # One reset rule for everything that reacts to a reset: TIMING
            # fires at once, a JUMP waits for a confirming read.
            confirmation = confirm_reset_events(
                detect_reset_events(
                    previous_state.snapshots,
                    state.snapshots,
                    seen_event_ids=frozenset(seen),
                ),
                state.snapshots,
                candidates=delivery_state.candidates,
                seen_event_ids=frozenset(seen),
            )
            reset_events = confirmation.events
            if confirmation.candidates != delivery_state.candidates:
                delivery_state = with_reset_candidates(delivery_state, confirmation.candidates)
                self._jrbar_reset_delivery_state = delivery_state
                if not reset_events:
                    self._persist_reset_delivery_state()
            # A waiting jump needs its confirming read within half an
            # hour; the idle cadence alone would usually miss it.
            note_reset_candidates(self, confirmation.candidates)
            reset_preferences = {preference.identity: preference for preference in settings.providers}
            if reset_events:
                for event in reset_events:
                    preference = reset_preferences.get((event.provider_id, event.source_instance_id))
                    enabled = bool(preference is not None and preference.reset_celebrations)
                    delivery_state = begin_reset_delivery(
                        delivery_state,
                        event,
                        ResetDeliverySettings(
                            overlay=enabled and preference.reset_overlay,
                            hardware=enabled and preference.reset_hardware,
                            notification=enabled and preference.reset_notification,
                            sound=enabled and preference.reset_sound,
                        ),
                        now=time.time(),
                )
                self._jrbar_reset_delivery_state = delivery_state
                self._persist_reset_delivery_state()
                # The app's Usage Center listens for ``quota_reset`` to
                # pulse the provider's card and re-fetch; the celebration
                # channels above are a user preference, this wire event is
                # not — a reset is a fact either way.
                _publish_reset_wire_events(self, reset_events)
            self._deliver_pending_reset_events()
            thresholds = {preference.identity: preference.threshold_remaining for preference in settings.providers}
            self._jrbar_provider_threshold_crossings = threshold_crossings(
                previous_state.snapshots,
                state.snapshots,
                thresholds,
            )
            # Usage hooks (usage_event_hooks): edges only, never states, run
            # by rule with a small environment and JSON on stdin. Their
            # quota_reset events are the confirmed ones above.
            hook_config = config_for_settings(self.settings)
            if hook_config.enabled and hook_config.rules:
                dispatch_usage_hooks(
                    hook_config,
                    detect_usage_hook_events(
                        previous_state.snapshots,
                        state.snapshots,
                        thresholds=thresholds,
                        reset_events=reset_events,
                    ),
                )
            # Pace as an interruption, not just a color: a lane that
            # JUST became projected-to-run-dry-before-reset earns one
            # content-free banner per window, through the same gates as
            # every other quota effect.
            self._alert_new_critical_pace(previous_state, state)
            self._alert_connection_loss(previous_state, state)
            self._report_reconnect_outcome(state)
            if previous_state != state and getattr(self, "_runtime_started", False):
                self.schedule_event_refresh()

        # --- Tightest limit beside the menu-bar icon (Codex Bar parity)

        def _usage_menu_settings(self):
            """Immutable worker or explicit-action snapshot; never UI-path I/O."""
            settings = getattr(self, "_jrbar_provider_presentation_settings", None)
            if type(settings) is not ProviderPresentationSettings:
                durable = getattr(
                    self,
                    "_jrbar_provider_usage_settings_snapshot",
                    None,
                )
                if type(durable) is ProviderUsageSettings:
                    settings = project_presentation_settings(durable)
            return settings if type(settings) is ProviderPresentationSettings else None

        def set_status(self, state, *, ask_count: int = 0, done_badge: bool = False) -> None:
            _BaseStatusBarController.set_status(self, state, ask_count=ask_count, done_badge=done_badge)
            self._append_quota_guarded()

        def _apply_status_accessibility_text(self, glance, finite_cues) -> None:
            # This base call rewrites the button title BARE, and it also
            # fires outside set_status on every finite-cue advance --
            # which wiped the quota percent for seconds at a time exactly
            # while cues were animating. Re-append after every rewrite
            # (the substring dedup makes it idempotent).
            _BaseStatusBarController._apply_status_accessibility_text(self, glance, finite_cues)
            self._append_quota_guarded()

        def _append_quota_guarded(self, *, wall_clock: Callable[[], float] = time.time) -> None:
            try:
                self._append_quota_to_status_title(wall_clock=wall_clock)
            except Exception as exc:
                # The status title is agent truth first; a quota suffix
                # failure must never take the tick down with it -- but a
                # PERSISTENT failure must not be silent either.
                if not getattr(self, "_quota_suffix_error_logged", False):
                    self._quota_suffix_error_logged = True
                    try:
                        _legacy.log_status_bar(f"menu-bar quota suffix: {exc}")
                    except Exception:
                        pass

        def screen_bar_quota_ember_level(self) -> float:
            """The base's 0.0 answered with the real reading: how far
            the tightest visible lane has sunk below its provider's
            threshold, 0 at-threshold to 1 fully out."""
            from .provider_usage_status_projection import screen_bar_quota_ember_level

            return screen_bar_quota_ember_level(self)

        def quota_runway_state(self):
            """The base withholds this LED (it collects no usage). The JR
            plane's gated lanes ARE the authority it waited for -- the same
            numbers the menu meters and the quota ember trust."""
            from .quota_runway import quota_runway_state_for_controller

            return quota_runway_state_for_controller(self)

        def _alert_new_critical_pace(self, previous_state, state) -> None:
            alert_new_critical_pace(self, previous_state, state, legacy=_legacy)

        def request_jr_usage_refresh(
            self,
            providers: tuple[str | tuple[str, str], ...],
            *,
            force=False,
            monotonic: Callable[[], float] = time.monotonic,
        ):
            now = float(monotonic())
            last = getattr(self, "_jr_usage_refresh_at", 0.0)
            if not force and now - last < 120.0:
                return
            self._jr_usage_refresh_at = now
            self._request_provider_usage(force=force, providers=tuple(providers))

        def jr_plane_owns_capacity(self, provider_id: str) -> bool:
            """Claude usage polling is owned here, not by the legacy scheduler."""
            return provider_id == "claude"

        def _report_reconnect_outcome(self, state) -> None:
            report_reconnect_outcome(self, state, legacy=_legacy)

        def _celebrate_quota_resets(self, events) -> None:
            celebrate_quota_resets(self, events, legacy=_legacy)

        def _persist_reset_delivery_state(self) -> None:
            state = reset_delivery_state(self)
            disposition = self._persistence_writer.submit(
                "provider-reset-events",
                lambda: save_reset_delivery_state(state),
                replace_pending=True,
            )
            if disposition.value.startswith("refused"):
                self._provider_usage_log("reset delivery state write not queued")

        def _deliver_pending_reset_events(self) -> None:
            from .provider_reset_settings_action import deliver_pending_reset_events

            deliver_pending_reset_events(self, legacy=_legacy)

        def _schedule_reset_delivery_retry(self, now: float) -> None:
            state = getattr(self, "_jrbar_reset_delivery_state", ResetDeliveryState())
            delay = next_reset_retry_delay(state, now=now)
            timer = getattr(self, "_jrbar_reset_delivery_timer", None)
            if delay is None:
                if timer is not None:
                    timer.invalidate()
                self._jrbar_reset_delivery_timer = None
                return
            if timer is not None:
                return
            self._jrbar_reset_delivery_timer = self._schedule_capacity_timer(
                max(0.05, delay),
                "retryPendingResetDeliveries:",
            )

        @_legacy.objc.IBAction
        def retryPendingResetDeliveries_(self, timer) -> None:
            if timer is not getattr(self, "_jrbar_reset_delivery_timer", None):
                return
            self._jrbar_reset_delivery_timer = None
            self._deliver_pending_reset_events()

        def _alert_connection_loss(self, previous_state, state) -> None:
            alert_connection_loss(self, previous_state, state, legacy=_legacy)

        def _active_usage_providers(self) -> frozenset[str]:
            """Providers with a MAIN session actually working right now --
            they own the menu-bar glance while they run."""
            from .provider_usage_status_projection import active_usage_providers

            return active_usage_providers(self, _legacy)

        def _append_quota_to_status_title(self, *, wall_clock: Callable[[], float] = time.time) -> None:
            from .provider_usage_status_projection import append_quota_to_status_title

            append_quota_to_status_title(self, wall_clock=wall_clock)

        def open_session(self, status, action: str | None, *, remember: bool) -> None:
            _BaseStatusBarController.open_session(
                self,
                status,
                profile_session_action(self, status, action),
                remember=remember,
            )

        @_legacy.objc.IBAction
        def refresh_(self, sender):
            self._deliver_pending_reset_events()
            self._request_provider_usage(force=False)
            result = _BaseStatusBarController.refresh_(self, sender)
            runtime = getattr(self, "_jrbar_optional_integration_runtime", None)
            snapshot = getattr(self, "last_snapshot", None)
            if runtime is not None and snapshot is not None:
                signal = (
                    "quota_exhausted"
                    if self.screen_bar_quota_ember_level() >= 1.0
                    else None
                )
                runtime.publish_creator_output(
                    self.display_aggregate_mode(snapshot),
                    signal=signal,
                )
            return result

        def why_panel_body(
            self,
            *,
            why_context=None,
            wall_clock: Callable[[], float] = time.time,
        ) -> str:
            body = _BaseStatusBarController.why_panel_body(
                self,
                why_context=why_context,
            )
            from .provider_usage_status_projection import provider_usage_why_panel_body

            return provider_usage_why_panel_body(
                self,
                body,
                wall_clock=wall_clock,
            )

        def applicationWillTerminate_(self, notification):
            if getattr(self, "_runtime_termination_started", False):
                return None
            from .deck_controller import stop_deck_runtime_reconfiguration

            stop_deck_runtime_reconfiguration(self)
            service = getattr(self, "_jrbar_provider_usage_service", None)
            if service is not None:
                service.close()
            optional_runtime = getattr(
                self,
                "_jrbar_optional_integration_runtime",
                None,
            )
            if optional_runtime is not None:
                optional_runtime.close()
            return _BaseStatusBarController.applicationWillTerminate_(
                self,
                notification,
            )


def install_provider_usage_status_bar():
    """Install the final provider controller once."""
    if _PROBE_IMPORT_MODE:
        from . import status_bar_legacy as legacy

        legacy.StatusBarController = JRProviderUsageStatusBarController
        return JRProviderUsageStatusBarController
    _host.install_status_bar_facade()
    _legacy.StatusBarController = JRProviderUsageStatusBarController
    return JRProviderUsageStatusBarController


__all__ = [
    "JRProviderUsageStatusBarController",
    "install_provider_usage_status_bar",
]
