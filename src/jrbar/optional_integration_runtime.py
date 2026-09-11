"""Background-only wiring for optional read and discovery integrations."""

from __future__ import annotations

import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from .creator_micro_adapter import CreatorMicro2Adapter, SemanticState
from .creator_micro_hidapi import HidApiTransport
from .creator_micro_lighting import CreatorMicroBrightnessProfile, CreatorMicroLightFrame, creator_micro_light_frame
from .deck_control_settings import DeckControlSettings, load_deck_controls
from .deck_input_dispatch import DeckInputDispatch
from .models import AgentMode


@dataclass(frozen=True, slots=True)
class CreatorMicroDiscoveryReceipt:
    available: bool
    matching_collections: int = 0
    reason: str | None = None


class CreatorMicroDiscoveryService:
    """Run one read-only HID enumeration from an existing background worker."""

    def __init__(
        self,
        *,
        transport_factory: Callable[[], Any] = HidApiTransport,
        callback: Callable[[CreatorMicroDiscoveryReceipt], None] | None = None,
    ) -> None:
        self._transport_factory = transport_factory
        self._callback = callback
        self.receipt: CreatorMicroDiscoveryReceipt | None = None

    def start(self) -> bool:
        try:
            count = len(self._transport_factory().enumerate())
            result = CreatorMicroDiscoveryReceipt(count > 0, count, None if count else "no_device")
        except Exception:
            result = CreatorMicroDiscoveryReceipt(False, reason="transport_unavailable")
        self.receipt = result
        if self._callback is not None:
            self._callback(result)
        return True

    def close(self) -> None:
        return None


@dataclass(frozen=True, slots=True)
class CreatorMicroOutputReceipt:
    available: bool
    reason: str
    detail: str = ""


def creator_semantic_state(
    mode: AgentMode,
    *,
    signal: str | None = None,
) -> SemanticState:
    signals = {
        "quota_exhausted": SemanticState.QUOTA_EXHAUSTED,
        "quota_warning": SemanticState.QUOTA_WARNING,
        "reset": SemanticState.RESET,
    }
    activity = {
        AgentMode.WAITING_FOR_INPUT: SemanticState.INPUT_REQUIRED,
        AgentMode.BLOCKED_ERROR: SemanticState.FAILURE,
        AgentMode.WORKING: SemanticState.ACTIVE,
        AgentMode.TOOL_RUNNING: SemanticState.ACTIVE,
        AgentMode.LONG_TASK_PROGRESS: SemanticState.ACTIVE,
        AgentMode.COMPLETED: SemanticState.COMPLETED,
    }.get(mode, SemanticState.IDLE)
    return max((activity, signals.get(signal, SemanticState.IDLE)), key=lambda state: state.priority)


def _creator_output_adapter(approved_serial: str) -> CreatorMicro2Adapter:
    transport = HidApiTransport(approved_serial=approved_serial)
    devices = transport.enumerate()
    if not devices:
        raise OSError("Creator Micro 2 not found")
    transport.enable_writes()
    return CreatorMicro2Adapter(transport, devices[0])


class CreatorMicroOutputService:
    """One HID owner for latest-wins output and optional bounded input polling."""

    def __init__(
        self,
        *,
        adapter_factory: Callable[[], Any] = _creator_output_adapter,
        approved_serial: str | None = None,
        callback: Callable[[CreatorMicroOutputReceipt], None] | None = None,
        input_callback: Callable[[list[dict[str, Any]]], None] | None = None,
        input_reset_callback: Callable[[], None] | None = None,
    ) -> None:
        if adapter_factory is _creator_output_adapter:
            if not approved_serial:
                raise ValueError("Creator Micro output requires an approved serial")
            self._adapter_factory = lambda: _creator_output_adapter(approved_serial)
        else:
            self._adapter_factory = adapter_factory
        self._callback = callback
        self._input_callback = input_callback
        self._input_reset_callback = input_reset_callback
        self._condition = threading.Condition()
        self._pending: tuple[AgentMode, str | None, CreatorMicroLightFrame | None] | None = None
        self._closed = False
        self._busy = False
        self._thread: threading.Thread | None = None

    def start(self) -> bool:
        with self._condition:
            if self._closed or self._thread is not None:
                return False
            self._thread = threading.Thread(
                target=self._run,
                name="JRBarCreatorMicroOutput",
                daemon=True,
            )
            self._thread.start()
            return True

    def submit(
        self, mode: AgentMode, *, signal: str | None = None,
        frame: CreatorMicroLightFrame | None = None,
    ) -> bool:
        if type(mode) is not AgentMode:
            raise TypeError("mode must be AgentMode")
        with self._condition:
            if self._closed:
                return False
            self._pending = (mode, signal, frame)
            self._condition.notify_all()
            return True

    def _publish(self, available: bool, reason: str, detail: str = "") -> None:
        if self._callback is not None:
            self._callback(CreatorMicroOutputReceipt(available, reason, detail[:256]))

    def _run(self) -> None:
        adapter = None
        last_output = None
        last_write_at = 0.0
        retry_delay = 1.0
        retry_at = 0.0
        try:
            while True:
                with self._condition:
                    if self._closed:
                        return
                    remaining = retry_at - time.monotonic()
                    if adapter is None and remaining > 0:
                        self._condition.wait(timeout=remaining)
                        continue
                if adapter is None:
                    # Why this attempt failed, so a retry that never succeeds
                    # still says what is wrong. A bare "reconnecting" reads the
                    # same whether the pad is asleep or macOS is refusing the
                    # open, which is the one thing the owner has to be told.
                    transient: tuple[str, str] | None = None
                    try:
                        candidate = self._adapter_factory()
                        connected = candidate.connect()
                        if connected.code != "connected":
                            candidate.close()
                            # input_monitoring_denied retries with the rest:
                            # it is the one refusal the owner can lift while
                            # the daemon is running, and the receipt goes on
                            # naming the setting until he does.
                            if connected.code not in {
                                "no_device", "transport_unavailable", "backoff", "input_monitoring_denied",
                            }:
                                self._publish(False, connected.code, connected.detail)
                                return
                            transient = (connected.code, connected.detail)
                            raise OSError(connected.code)
                        adapter = candidate
                        last_output = None
                        negotiated = adapter.negotiate_capabilities()
                        if negotiated.code != "capabilities_negotiated":
                            self._publish(False, negotiated.code, negotiated.detail)
                            if negotiated.code not in {"timeout", "transport_unavailable", "backoff"}:
                                return
                            raise OSError(negotiated.code)
                        if not adapter.capabilities().methods.intersection({"v.oai.thstatus", "lights.preview"}):
                            self._publish(False, "unsupported_firmware")
                            return
                        if self._input_reset_callback is not None:
                            self._input_reset_callback()
                        self._publish(True, "ready")
                        retry_delay = 1.0
                    except OSError as error:
                        if adapter is not None:
                            adapter.close()
                            adapter = None
                        if self._input_reset_callback is not None:
                            self._input_reset_callback()
                        code, detail = transient or ("reconnecting", str(error))
                        self._publish(False, code, detail)
                        retry_at = time.monotonic() + retry_delay
                        retry_delay = min(10.0, retry_delay * 2)
                        continue
                try:
                    with self._condition:
                        if self._pending is None and not self._closed:
                            self._condition.wait(timeout=0.05 if self._input_callback else 0.5)
                        if self._closed:
                            return
                        pending, self._pending = self._pending, None
                        self._busy = pending is not None
                    failed = False
                    if pending is not None:
                        mode, signal, frame = pending
                        state = creator_semantic_state(mode, signal=signal)
                        output = (state, frame)
                        if output != last_output or time.monotonic() - last_write_at >= 1.0:
                            methods = adapter.capabilities().methods
                            preview = "lights.preview" in methods and frame is not None and not frame.slots
                            if preview:
                                result = adapter.apply_preview(frame)
                            elif "v.oai.thstatus" in methods:
                                result = adapter.apply(state, frame.params()) if frame is not None else adapter.apply(state)
                            else:
                                self._publish(False, "per_key_output_unsupported")
                                return
                            self._publish(result.code == "applied",
                                          "aggregate_preview" if preview and result.code == "applied" else result.code,
                                          result.detail)
                            if result.code not in {"applied", "timeout", "transport_unavailable", "backoff"}:
                                return
                            failed = result.code != "applied"
                            if not failed:
                                last_output, last_write_at = output, time.monotonic()
                    # Poll even with actions disabled: this detects competing owners
                    # and disconnects. Never replay notifications after reconnect.
                    inputs = adapter.poll_inputs() if not failed else []
                    if adapter.conflict.active:
                        self._publish(False, "device_conflict")
                        return
                    failed = failed or not adapter.connected
                    if not failed and inputs and self._input_callback is not None:
                        self._input_callback(inputs)
                    with self._condition:
                        self._busy = False
                        self._condition.notify_all()
                    if failed:
                        adapter.close()
                        adapter = None
                        if self._input_reset_callback is not None:
                            self._input_reset_callback()
                        self._publish(False, "reconnecting")
                        retry_at = time.monotonic() + retry_delay
                except Exception as error:
                    # One bad packet or a bug in a poll used to fall through
                    # to the outer except, which closed the service for good:
                    # deck I/O dead until the daemon restarted. An unexpected
                    # failure is a device failure -- drop the adapter and take
                    # the same reconnect path a disconnect would.
                    with self._condition:
                        self._busy = False
                        self._condition.notify_all()
                    if adapter is not None:
                        try:
                            adapter.close()
                        except Exception:
                            pass
                        adapter = None
                    if self._input_reset_callback is not None:
                        self._input_reset_callback()
                    self._publish(False, "reconnecting", f"{type(error).__name__}: {error}")
                    retry_at = time.monotonic() + retry_delay
                    retry_delay = min(10.0, retry_delay * 2)
        except Exception:
            self._publish(False, "transport_unavailable")
        finally:
            if self._input_reset_callback is not None:
                self._input_reset_callback()
            if adapter is not None:
                try:
                    adapter.close()
                except OSError:
                    pass
            with self._condition:
                self._busy = False
                self._pending = None
                self._closed = True
                self._condition.notify_all()

    def wait_until_idle(self, timeout: float | None = None) -> bool:
        deadline = None if timeout is None else time.monotonic() + timeout
        with self._condition:
            while self._pending is not None or self._busy:
                remaining = None if deadline is None else deadline - time.monotonic()
                if remaining is not None and remaining <= 0:
                    return False
                self._condition.wait(remaining)
            return True

    def close(self) -> None:
        with self._condition:
            self._closed = True
            self._pending = None
            self._condition.notify_all()
            thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=1.0)

    def wait_until_stopped(self, timeout: float) -> bool:
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=timeout)
        return thread is None or not thread.is_alive()


class OptionalIntegrationRuntime:
    """Load optional settings and configure services away from the AppKit thread."""

    def __init__(
        self,
        target: object,
        *,
        settings_loader: Callable[[], object],
        deck_settings_loader: Callable[[], DeckControlSettings] = load_deck_controls,
        creator_service_factory: Callable[..., object] = CreatorMicroOutputService,
        wall_clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._target = target
        self._settings_loader = settings_loader
        self._deck_settings_loader = deck_settings_loader
        self._creator_service_factory = creator_service_factory
        self._wall_clock = wall_clock
        self._monotonic = monotonic
        self._lock = threading.RLock()
        self._closed = False
        self._started = False
        self._configured = threading.Event()
        self._creator_service: object | None = None
        self._deck_dispatch: DeckInputDispatch | None = None

    def start(self) -> bool:
        with self._lock:
            if self._closed or self._started:
                return False
            self._started = True
        threading.Thread(
            target=self._configure,
            name="JRBarOptionalIntegrations",
            daemon=True,
        ).start()
        return True

    def wait_until_configured(self, timeout: float | None = None) -> bool:
        return self._configured.wait(timeout)

    def _configure(self) -> None:
        from .deck_control_center import ensure_deck_board
        ensure_deck_board(self._target)
        try:
            loaded = self._settings_loader()
            settings = getattr(loaded, "settings", loaded)
            with self._lock:
                if self._closed:
                    return
                setattr(
                    self._target,
                    "_creator_micro_output_enabled",
                    getattr(settings, "creator_micro_enabled", False) is True,
                )
            try:
                controls = self._deck_settings_loader()
                controls_error = None
            except (OSError, ValueError, TypeError):
                controls = DeckControlSettings()
                controls_error = "Deck settings could not be read safely."
            with self._lock:
                if self._closed:
                    return
                if controls_error is None:
                    setattr(self._target, "_deck_control_settings", controls)
                    setattr(self._target, "_deck_control_settings_error", None)
                else:
                    setattr(self._target, "_deck_control_settings", None)
                    setattr(self._target, "_deck_control_settings_error", controls_error)
                self._deck_dispatch = DeckInputDispatch(self._target, controls)
            if getattr(settings, "creator_micro_enabled", False) is True:
                approved_serial = getattr(
                    settings,
                    "creator_micro_device_serial",
                    None,
                )
                if not isinstance(approved_serial, str) or not approved_serial.strip():
                    self._publish_creator_receipt(
                        CreatorMicroOutputReceipt(False, "device_identity_required")
                    )
                    return
                service = self._creator_service_factory(
                    approved_serial=approved_serial,
                    callback=self._publish_creator_receipt,
                    input_callback=self._deck_dispatch.receive,
                    input_reset_callback=self._reset_deck_connection,
                )
                with self._lock:
                    if self._closed:
                        self._close_service(service)
                        return
                    self._creator_service = service
                    service.start()
        finally:
            self._configured.set()
            with self._lock:
                if not self._closed and getattr(self._target, "deck_settings_pane", None) is not None:
                    dispatch = getattr(self._target, "performSelectorOnMainThread_withObject_waitUntilDone_", None)
                    if callable(dispatch):
                        dispatch("applyDeckControlsLoaded:", getattr(self._target, "_deck_control_settings", None), False)

    def _publish_creator_receipt(self, receipt: CreatorMicroOutputReceipt) -> None:
        with self._lock:
            if self._closed:
                return
            setattr(self._target, "_creator_micro_output_receipt", receipt)
            dispatch = getattr(
                self._target,
                "performSelectorOnMainThread_withObject_waitUntilDone_",
                None,
            )
            if callable(dispatch):
                dispatch("applyCreatorMicroOutputReceipt:", receipt, False)

    def publish_creator_output(
        self,
        mode: AgentMode,
        *,
        signal: str | None = None,
    ) -> bool:
        with self._lock:
            if self._closed:
                return False
            service = self._creator_service
        from .deck_control_center import refresh_deck_board
        board = refresh_deck_board(self._target)
        submit = getattr(service, "submit", None)
        if not callable(submit):
            return False
        from .colors import ColorSettings

        colors = getattr(getattr(self._target, "settings", None), "colors", None)
        brightness_policy = getattr(self._target, "effective_brightness_for_device", None)
        brightness = brightness_policy(CreatorMicroBrightnessProfile()) / 255 if callable(brightness_policy) else 0.4
        frame = creator_micro_light_frame(
            creator_semantic_state(mode, signal=signal).value,
            colors=colors if type(colors) is ColorSettings else None,
            brightness=brightness,
            idle_off=not callable(brightness_policy),
        )
        controls = getattr(self._target, "_deck_control_settings", None)
        if controls is not None and controls.session_mode and signal is None:
            from .creator_micro_lighting import creator_micro_session_frame
            frame = creator_micro_session_frame(board, colors=colors if type(colors) is ColorSettings else None,
                                                brightness=brightness)
        return bool(submit(mode, signal=signal, frame=frame))

    @staticmethod
    def _close_service(service: object | None) -> None:
        close = getattr(service, "close", None)
        if callable(close):
            close()

    def _reset_deck_connection(self) -> None:
        with self._lock:
            dispatch = self._deck_dispatch
        runner = getattr(self._target, "_deck_automation_runner", None)
        if runner is not None:
            self._target._deck_automation_runner = None
            runner.close()
        if dispatch is not None:
            dispatch.reset_connection()

    def revoke_deck_input(self) -> None:
        runner = getattr(self._target, "_deck_automation_runner", None)
        if runner is not None:
            self._target._deck_automation_runner = None
            runner.close()
        with self._lock:
            dispatch = self._deck_dispatch
        if dispatch is not None:
            dispatch.close()

    def wait_until_stopped(self, timeout: float) -> bool:
        with self._lock:
            service = self._creator_service
        wait = getattr(service, "wait_until_stopped", None)
        return service is None or bool(callable(wait) and wait(timeout))

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            creator_service = self._creator_service
            deck_dispatch = self._deck_dispatch
        if deck_dispatch is not None:
            deck_dispatch.close()
        self._close_service(creator_service)


def start_optional_integration_runtime(target: object) -> OptionalIntegrationRuntime:
    """Start the production runtime without doing settings or device I/O inline."""
    from .integration_settings import load_integration_settings

    runtime = OptionalIntegrationRuntime(target, settings_loader=load_integration_settings)
    runtime.start()
    return runtime


def set_creator_micro_output_enabled_async(target: object, enabled: bool) -> None:
    """Persist an explicit output choice and reconcile without blocking AppKit."""
    from .creator_micro_settings import save_creator_micro_choice_async

    save_creator_micro_choice_async(target, enabled)


__all__ = [
    "CreatorMicroDiscoveryReceipt",
    "CreatorMicroDiscoveryService",
    "CreatorMicroOutputReceipt",
    "CreatorMicroOutputService",
    "OptionalIntegrationRuntime",
    "creator_semantic_state",
    "set_creator_micro_output_enabled_async",
    "start_optional_integration_runtime",
]
