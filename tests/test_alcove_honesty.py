"""Alcove following must say what it is doing, or why it is not.

The owner reported "Alcove mode doesn't seem to be working" and NOTHING
could answer it. Screen Recording never granted, Alcove not running, the
window moving mid-capture and a genuinely empty capture were the SAME
value -- a bare ``None`` from capture_alcove_observation, swallowed by a
blanket ``except Exception``. There were zero lines matching "alcove" in
the app's own log, no diagnostic code, and a settings switch that read ON
in every one of those failures.

These tests pin the four outcomes apart, pin the preflight that
distinguishes the permission case, and pin the doctor code.
"""

from __future__ import annotations

import sys
import threading
import time
from types import SimpleNamespace

import pytest

from jrbar.alcove_observation import (
    AlcoveCaptureOutcome,
    AlcoveCaptureRequest,
    AlcoveCaptureStatus,
    AlcoveConfidenceState,
    AlcoveObservation,
    AlcoveObservationBuffer,
    AlcoveObservationWorker,
    alcove_follow_blocker,
    capture_alcove_observation,
    latest_alcove_status,
    note_alcove_status,
    request_screen_recording_access,
    reset_alcove_status,
    reset_screen_recording_cache,
    screen_recording_granted,
)


@pytest.fixture(autouse=True)
def _isolated_alcove_state():
    """Process-wide permission cache and status record are shared state."""
    reset_screen_recording_cache()
    reset_alcove_status()
    yield
    reset_screen_recording_cache()
    reset_alcove_status()


def _request(**changes) -> AlcoveCaptureRequest:
    values = {
        "request_id": 11,
        "generation": 7,
        "screen_id": "built-in:1",
        "display_id": 1,
        "window_number": 99,
        "screen_x": 0.0,
        "screen_y": 0.0,
        "screen_width": 1512.0,
        "screen_height": 982.0,
        "window_x": 444.0,
        "window_y": 0.0,
        "window_width": 624.0,
        "menu_band_height": 37.0,
        "scale": 2.0,
        "requested_at": 100.0,
    }
    values.update(changes)
    return AlcoveCaptureRequest(**values)


def _observation(**changes) -> AlcoveObservation:
    contour = (
        (464.0, 8.0),
        (464.0, 32.0),
        (736.0, 32.0),
        (736.0, 8.0),
        (464.0, 8.0),
    )
    values = {
        "request_id": 11,
        "generation": 7,
        "screen_id": "built-in:1",
        "window_number": 99,
        "center_x": 600.0,
        "width": 272.0,
        "height": 32.0,
        "contour": contour,
        "captured_at": 100.0,
        "confidence": 0.95,
    }
    values.update(changes)
    return AlcoveObservation(**values)


class _FakeImage:
    """A CGImage stand-in with a fully transparent (unmeasurable) band."""

    def __init__(self, *, width: int = 8, height: int = 4, data: object | None = b"") -> None:
        self.width = width
        self.height = height
        self.data = bytes(width * height * 4) if data == b"" else data


class _FakeQuartz:
    """Only the calls capture_alcove_observation makes, nothing else."""

    kCGWindowListOptionIncludingWindow = 8
    kCGWindowImageNominalResolution = 16

    def __init__(self, *, image: object | None, provider: object = object()) -> None:
        self.image = image
        self.provider = provider
        self.create_calls = 0

    def CGRectMake(self, x, y, width, height):
        return (x, y, width, height)

    def CGWindowListCreateImage(self, *_args):
        self.create_calls += 1
        return self.image

    def CGImageGetWidth(self, image):
        return image.width

    def CGImageGetHeight(self, image):
        return image.height

    def CGImageGetBitsPerPixel(self, _image):
        return 32

    def CGImageGetBytesPerRow(self, image):
        return image.width * 4

    def CGImageGetBitmapInfo(self, _image):
        # kCGImageAlphaPremultipliedLast, big-endian: alpha at byte 3.
        return 1

    def CGImageGetDataProvider(self, _image):
        return self.provider

    def CGDataProviderCopyData(self, _provider):
        return self.image.data


def _fake_legacy_capture(request, quartz):
    probe_height = request.menu_band_height * 2.0
    return quartz.CGWindowListCreateImage(
        quartz.CGRectMake(
            request.window_x,
            request.window_y,
            request.window_width,
            probe_height,
        ),
        quartz.kCGWindowListOptionIncludingWindow,
        request.window_number,
        quartz.kCGWindowImageNominalResolution,
    )


# --- 1. the four outcomes are four values, not one None -----------------


def test_denied_screen_recording_is_named_and_never_captures__and_2_more(monkeypatch) -> None:
    # --- scenario: denied_screen_recording_is_named_and_never_captures
    """The permission case must be knowable WITHOUT attempting a capture.

    Without preflight, a denied capture comes back as a blank image and is
    indistinguishable from "Alcove is showing nothing".
    """
    quartz = _FakeQuartz(image=_FakeImage())
    monkeypatch.setitem(sys.modules, "Quartz", quartz)

    outcome = capture_alcove_observation(
        _request(), screen_recording=False, image_capture=_fake_legacy_capture
    )

    assert outcome.status is AlcoveCaptureStatus.SCREEN_RECORDING_DENIED
    assert outcome.observation is None
    assert quartz.create_calls == 0, "denied must not even try to capture"

    # --- scenario: a_missing_window_is_not_an_unusable_image
    monkeypatch.undo()
    monkeypatch.setitem(sys.modules, "Quartz", _FakeQuartz(image=None))
    missing = capture_alcove_observation(
        _request(), screen_recording=True, image_capture=_fake_legacy_capture
    )

    monkeypatch.setitem(sys.modules, "Quartz", _FakeQuartz(image=_FakeImage()))
    unusable = capture_alcove_observation(
        _request(), screen_recording=True, image_capture=_fake_legacy_capture
    )

    assert missing.status is AlcoveCaptureStatus.WINDOW_UNAVAILABLE
    assert unusable.status is AlcoveCaptureStatus.IMAGE_UNUSABLE
    assert missing.status is not unusable.status

    # --- scenario: a_nil_data_provider_is_unusable_rather_than_a_crash
    monkeypatch.undo()
    monkeypatch.setitem(
        sys.modules,
        "Quartz",
        _FakeQuartz(image=_FakeImage(), provider=None),
    )

    outcome = capture_alcove_observation(
        _request(), screen_recording=True, image_capture=_fake_legacy_capture
    )

    assert outcome.status is AlcoveCaptureStatus.IMAGE_UNUSABLE



def test_an_unexpected_failure_still_cannot_raise_but_must_say_so__and_2_more(monkeypatch) -> None:
    # --- scenario: an_unexpected_failure_still_cannot_raise_but_must_say_so
    class Exploding(_FakeQuartz):
        def CGWindowListCreateImage(self, *_args):
            raise RuntimeError("no window server")

    monkeypatch.setitem(sys.modules, "Quartz", Exploding(image=None))

    outcome = capture_alcove_observation(
        _request(), screen_recording=True, image_capture=_fake_legacy_capture
    )

    assert outcome.status is AlcoveCaptureStatus.CAPTURE_FAILED
    assert outcome.observation is None

    # --- scenario: a_measurable_capsule_reports_captured_with_its_geometry
    monkeypatch.undo()
    """The success path must survive being made honest."""
    width_px, height_px = 624, 74
    pixels = bytearray(width_px * height_px * 4)
    for y in range(8, 41):
        for x in range(176, 448):
            pixels[(y * width_px + x) * 4 + 3] = 255
    monkeypatch.setitem(
        sys.modules,
        "Quartz",
        _FakeQuartz(
            image=_FakeImage(width=width_px, height=height_px, data=bytes(pixels))
        ),
    )

    outcome = capture_alcove_observation(
        _request(), screen_recording=True, image_capture=_fake_legacy_capture
    )

    assert outcome.status is AlcoveCaptureStatus.CAPTURED
    assert outcome.observation is not None
    assert outcome.observation.width == pytest.approx(272.0, abs=1.0)

    # --- scenario: macos_15_never_falls_back_to_obsolete_window_capture
    monkeypatch.undo()
    import jrbar.alcove_observation as module

    quartz = _FakeQuartz(image=_FakeImage())
    monkeypatch.setitem(sys.modules, "Quartz", quartz)
    monkeypatch.setattr(module, "_macos_major_version", lambda: 15)
    monkeypatch.setattr(
        module,
        "_screen_capture_kit_image",
        lambda _request: module._CAPTURE_API_UNAVAILABLE,
    )

    outcome = capture_alcove_observation(_request(), screen_recording=True)

    assert outcome.status is AlcoveCaptureStatus.CAPTURE_API_UNAVAILABLE
    assert quartz.create_calls == 0



def test_macos_15_screen_capture_kit_image_uses_the_existing_scanner__and_1_more(monkeypatch,) -> None:
    # --- scenario: macos_15_screen_capture_kit_image_uses_the_existing_scanner
    import jrbar.alcove_observation as module

    width_px, height_px = 624, 74
    pixels = bytearray(width_px * height_px * 4)
    for y in range(8, 41):
        for x in range(176, 448):
            pixels[(y * width_px + x) * 4 + 3] = 255
    image = _FakeImage(width=width_px, height=height_px, data=bytes(pixels))
    quartz = _FakeQuartz(image=image)
    monkeypatch.setitem(sys.modules, "Quartz", quartz)
    monkeypatch.setattr(module, "_macos_major_version", lambda: 15)
    monkeypatch.setattr(module, "_screen_capture_kit_image", lambda _request: image)

    outcome = capture_alcove_observation(_request(), screen_recording=True)

    assert outcome.status is AlcoveCaptureStatus.CAPTURED
    assert outcome.observation is not None
    assert outcome.observation.width == pytest.approx(272.0, abs=1.0)
    assert quartz.create_calls == 0

    # --- scenario: screen_capture_kit_targets_only_the_selected_alcove_window
    monkeypatch.undo()
    import jrbar.alcove_observation as module

    captured_image = object()
    selected_window = SimpleNamespace(
        windowID=lambda: 99,
        owningApplication=lambda: SimpleNamespace(
            bundleIdentifier=lambda: module.ALCOVE_BUNDLE_ID
        ),
    )
    unrelated_window = SimpleNamespace(
        windowID=lambda: 41,
        owningApplication=lambda: SimpleNamespace(
            bundleIdentifier=lambda: "com.example.Other"
        ),
    )

    class Shareable:
        @classmethod
        def getShareableContentExcludingDesktopWindows_onScreenWindowsOnly_completionHandler_(
            cls, _exclude_desktop, _on_screen_only, callback
        ) -> None:
            callback(
                SimpleNamespace(windows=lambda: [unrelated_window, selected_window]),
                None,
            )

    class Filter:
        @classmethod
        def alloc(cls):
            return cls()

        def initWithDesktopIndependentWindow_(self, window):
            self.window = window
            return self

    class Configuration:
        last = None

        @classmethod
        def alloc(cls):
            cls.last = cls()
            return cls.last

        def init(self):
            return self

        def setWidth_(self, value):
            self.width = value

        def setHeight_(self, value):
            self.height = value

        def setShowsCursor_(self, value):
            self.shows_cursor = value

        def setSourceRect_(self, value):
            self.source_rect = value

    class ScreenshotManager:
        @classmethod
        def captureImageWithFilter_configuration_completionHandler_(
            cls, capture_filter, configuration, callback
        ) -> None:
            assert capture_filter.window is selected_window
            assert configuration is Configuration.last
            callback(captured_image, None)

    monkeypatch.setitem(
        sys.modules,
        "Quartz",
        SimpleNamespace(CGRectMake=lambda x, y, width, height: (x, y, width, height)),
    )
    result = module._screen_capture_kit_image(
        _request(),
        api=(Shareable, Filter, Configuration, ScreenshotManager),
    )

    assert result is captured_image
    assert Configuration.last.width == 1248
    assert Configuration.last.height == 148
    assert Configuration.last.shows_cursor is False
    assert Configuration.last.source_rect == (0.0, 0.0, 624.0, 74.0)



def test_an_outcome_cannot_claim_success_with_nothing_to_show__and_2_more() -> None:
    # --- scenario: an_outcome_cannot_claim_success_with_nothing_to_show
    """The pairing is the invariant that replaces None, so enforce it."""
    with pytest.raises(ValueError, match="observation"):
        AlcoveCaptureOutcome(AlcoveCaptureStatus.CAPTURED)
    with pytest.raises(ValueError, match="observation"):
        AlcoveCaptureOutcome(AlcoveCaptureStatus.IMAGE_UNUSABLE, _observation())
    with pytest.raises(ValueError, match="not_following"):
        AlcoveCaptureOutcome(AlcoveCaptureStatus.NOT_FOLLOWING)

    # --- scenario: the_worker_reports_the_reason_the_buffer_never_could
    """An empty buffer is not a diagnosis.

    The buffer only ever carries successes, so before this the main thread
    could see that nothing arrived and still had no idea why.
    """
    buffer = AlcoveObservationBuffer()
    done = threading.Event()

    def capture(_request):
        done.set()
        return AlcoveCaptureOutcome(AlcoveCaptureStatus.SCREEN_RECORDING_DENIED)

    worker = AlcoveObservationWorker(buffer, capture=capture)
    try:
        worker.reconcile(_request(requested_at=time.monotonic()))
        assert done.wait(2.0)
        assert worker.wait_idle(timeout_seconds=2.0)
        assert worker.last_status is AlcoveCaptureStatus.SCREEN_RECORDING_DENIED
        assert buffer.take() is None
    finally:
        worker.close(timeout_seconds=1.0)

    # --- scenario: a_capture_that_declines_to_say_why_is_a_failure_not_a_silence
    buffer = AlcoveObservationBuffer()
    done = threading.Event()

    def capture(_request):
        done.set()
        return None

    worker = AlcoveObservationWorker(buffer, capture=capture)
    try:
        worker.reconcile(_request(requested_at=time.monotonic()))
        assert done.wait(2.0)
        assert worker.wait_idle(timeout_seconds=2.0)
        assert worker.last_status is AlcoveCaptureStatus.CAPTURE_FAILED
    finally:
        worker.close(timeout_seconds=1.0)



# --- 3. preflight: cached, and never a surprise prompt ------------------


def test_preflight_is_cached_and_refreshable__and_1_more() -> None:
    # --- scenario: preflight_is_cached_and_refreshable
    calls: list[int] = []

    def probe() -> bool:
        calls.append(1)
        return True

    first = screen_recording_granted(now=100.0, preflight=probe)
    second = screen_recording_granted(now=101.0, preflight=probe)

    assert (first, second) == (True, True)
    assert len(calls) == 1, "a per-frame TCC probe is not a cache"

    # It genuinely changes: the user can grant or revoke it while we run.
    assert screen_recording_granted(now=200.0, preflight=probe) is True
    assert len(calls) == 2
    assert screen_recording_granted(force=True, now=200.0, preflight=lambda: False) is False

    # --- scenario: an_unaskable_preflight_is_unknown_not_denied
    """None is not False. Telling someone their permission is off when we
    simply could not ask is the same dishonesty, pointing the other way."""
    assert screen_recording_granted(preflight=lambda: None) is None
    reset_screen_recording_cache()
    assert alcove_follow_blocker(following=True) is not (
        AlcoveCaptureStatus.SCREEN_RECORDING_DENIED
    )



def test_default_window_presence_lookup_is_cached_and_never_runs_inline(
    monkeypatch,
) -> None:
    import jrbar.alcove_observation as module

    queued: list[object] = []
    calls = 0

    def query() -> bool:
        nonlocal calls
        calls += 1
        return True

    module.reset_alcove_window_presence_cache()
    monkeypatch.setattr(module, "_query_alcove_window_presence", query)
    monkeypatch.setattr(
        module,
        "_start_alcove_window_presence_refresh",
        queued.append,
    )

    for _ in range(100):
        assert module.alcove_window_present(now=0.0) is None
    assert calls == 0
    assert len(queued) == 1

    queued.pop()()
    assert module.alcove_window_present(now=0.5) is True
    assert calls == 1
    module.reset_alcove_window_presence_cache()


def test_nothing_on_the_background_path_may_request_access(monkeypatch) -> None:
    """A permission dialog nobody asked for is its own bug."""
    requested: list[int] = []

    def never(*_args, **_kwargs):
        requested.append(1)
        return True

    import jrbar.alcove_observation as module

    monkeypatch.setattr(module, "_preflight_screen_capture_access", lambda: False)
    quartz = SimpleNamespace(
        CGRequestScreenCaptureAccess=never,
        CGPreflightScreenCaptureAccess=lambda: False,
    )
    monkeypatch.setattr(module, "_quartz", lambda: quartz)

    screen_recording_granted(force=True)
    capture_alcove_observation(_request())
    alcove_follow_blocker(following=True)

    assert requested == [], "only an explicit user action may prompt"

    # ...and the explicit action does ask, exactly once.
    assert request_screen_recording_access() is True
    assert requested == [1]


def test_requesting_access_invalidates_the_cached_answer__and_1_more() -> None:
    # --- scenario: requesting_access_invalidates_the_cached_answer
    assert screen_recording_granted(preflight=lambda: False) is False
    request_screen_recording_access(request=lambda: True)
    assert screen_recording_granted(preflight=lambda: True) is True

    # --- scenario: a_repeated_outcome_is_recorded_but_reported_once
    assert note_alcove_status(AlcoveCaptureStatus.SCREEN_RECORDING_DENIED) is True
    assert note_alcove_status(AlcoveCaptureStatus.SCREEN_RECORDING_DENIED) is False
    assert note_alcove_status(AlcoveCaptureStatus.CAPTURED) is True
    snapshot = latest_alcove_status()
    assert snapshot is not None
    assert snapshot.status is AlcoveCaptureStatus.CAPTURED



def test_doctor_reports_the_permission_as_its_own_code(monkeypatch) -> None:
    from jrbar import doctor

    note_alcove_status(AlcoveCaptureStatus.SCREEN_RECORDING_DENIED)
    monkeypatch.setattr(doctor, "_alcove_following_enabled", lambda: True)
    monkeypatch.setattr(doctor, "alcove_follow_blocker", lambda **_kwargs: None)

    finding = doctor._alcove_follow_state_probe()

    assert finding.check is doctor.DiagnosticCheck.ALCOVE_FOLLOW_STATE
    assert finding.code is doctor.DiagnosticCode.NOT_PERMITTED
    assert finding.count == 0 and finding.limit == 1



def test_every_outcome_has_a_distinct_doctor_code__and_2_more(monkeypatch) -> None:
    # --- scenario: every_outcome_has_a_distinct_doctor_code
    for status, code_name in [
        (AlcoveCaptureStatus.CAPTURED, "HEALTHY"),
        (AlcoveCaptureStatus.SCREEN_RECORDING_DENIED, "NOT_PERMITTED"),
        (AlcoveCaptureStatus.WINDOW_UNAVAILABLE, "NOT_RUNNING"),
        (AlcoveCaptureStatus.IMAGE_UNUSABLE, "UNSUPPORTED"),
        (AlcoveCaptureStatus.CAPTURE_FAILED, "RECOVERING"),
    ]:
        from jrbar import doctor

        note_alcove_status(status)
        monkeypatch.setattr(doctor, "_alcove_following_enabled", lambda: True)
        monkeypatch.setattr(doctor, "alcove_follow_blocker", lambda **_kwargs: None)

        finding = doctor._alcove_follow_state_probe()

        assert finding.code is getattr(doctor.DiagnosticCode, code_name)

    # --- scenario: doctor_never_upgrades_no_obvious_blocker_into_success
    monkeypatch.undo()
    """"Nothing is in the way" is not "it works"."""
    import jrbar.alcove_observation as module
    from jrbar import doctor

    monkeypatch.setattr(doctor, "_alcove_following_enabled", lambda: True)
    monkeypatch.setattr(module, "_preflight_screen_capture_access", lambda: True)
    monkeypatch.setattr(module, "alcove_window_present", lambda **_k: True)

    finding = doctor._alcove_follow_state_probe()

    assert finding.code is doctor.DiagnosticCode.RECOVERING

    # --- scenario: a_stale_reading_is_not_presented_as_current
    monkeypatch.undo()
    import jrbar.alcove_observation as module
    from jrbar import doctor

    note_alcove_status(
        AlcoveCaptureStatus.CAPTURED,
        now=time.monotonic() - module.ALCOVE_STATUS_MAX_AGE_SECONDS - 5.0,
    )
    monkeypatch.setattr(doctor, "_alcove_following_enabled", lambda: True)
    monkeypatch.setattr(module, "_preflight_screen_capture_access", lambda: True)
    monkeypatch.setattr(module, "alcove_window_present", lambda **_k: True)

    finding = doctor._alcove_follow_state_probe()

    assert finding.code is doctor.DiagnosticCode.STALE



def test_the_alcove_finding_is_in_the_manifest_and_encodes__and_1_more(monkeypatch) -> None:
    # --- scenario: the_alcove_finding_is_in_the_manifest_and_encodes
    from jrbar import doctor

    note_alcove_status(AlcoveCaptureStatus.SCREEN_RECORDING_DENIED)
    monkeypatch.setattr(doctor, "_alcove_following_enabled", lambda: True)
    monkeypatch.setattr(doctor, "alcove_follow_blocker", lambda **_kwargs: None)
    result = doctor.collect_diagnostics()
    encoded = doctor.encode_diagnostic_result(result).decode("ascii")

    assert (
        doctor.DiagnosticCheck.ALCOVE_FOLLOW_STATE
        in tuple(field.check for field in doctor.DIAGNOSTIC_MANIFEST.fields)
    )
    assert '"check":"alcove_follow_state"' in encoded
    assert '"code":"not_permitted"' in encoded
    assert (
        result.finding(doctor.DiagnosticCheck.ALCOVE_FOLLOW_STATE).code
        is doctor.DiagnosticCode.NOT_PERMITTED
    )

    # --- scenario: doctor_maps_every_confidence_state
    monkeypatch.undo()
    for state, code in [
        (AlcoveConfidenceState.FRESH, "HEALTHY"),
        (AlcoveConfidenceState.STALE, "STALE"),
        (AlcoveConfidenceState.PERMISSION_DENIED, "NOT_PERMITTED"),
        (AlcoveConfidenceState.DISCONNECTED, "NOT_RUNNING"),
        (AlcoveConfidenceState.UNSUPPORTED, "UNSUPPORTED"),
        (AlcoveConfidenceState.NOT_FOLLOWING, "NOT_CONFIGURED"),
        (AlcoveConfidenceState.RECOVERING, "RECOVERING"),
    ]:
        from jrbar import doctor

        projection = SimpleNamespace(state=state)
        monkeypatch.setattr(doctor, "_alcove_following_enabled", lambda: True)
        monkeypatch.setattr(doctor, "alcove_follow_blocker", lambda **_kwargs: None)
        monkeypatch.setattr(doctor, "latest_alcove_status", lambda: None)
        monkeypatch.setattr(doctor, "project_alcove_confidence", lambda **_kwargs: projection)

        finding = doctor._alcove_follow_state_probe()

        assert finding.code is getattr(doctor.DiagnosticCode, code)
        assert finding.count == int(state is AlcoveConfidenceState.FRESH)



def test_doctor_manifest_is_version_six_and_allows_seven_codes() -> None:
    from jrbar import doctor

    assert doctor.DOCTOR_VERSION == 6
    field = next(
        field
        for field in doctor.DIAGNOSTIC_MANIFEST.fields
        if field.check is doctor.DiagnosticCheck.ALCOVE_FOLLOW_STATE
    )
    assert set(field.allowed_codes) >= {
        doctor.DiagnosticCode.HEALTHY,
        doctor.DiagnosticCode.STALE,
        doctor.DiagnosticCode.NOT_PERMITTED,
        doctor.DiagnosticCode.NOT_RUNNING,
        doctor.DiagnosticCode.UNSUPPORTED,
        doctor.DiagnosticCode.NOT_CONFIGURED,
        doctor.DiagnosticCode.RECOVERING,
    }


def test_expired_captured_snapshot_maps_to_stale(monkeypatch) -> None:
    import jrbar.alcove_observation as module
    from jrbar import doctor

    now = 100.0
    note_alcove_status(
        AlcoveCaptureStatus.CAPTURED,
        now=now - module.ALCOVE_STATUS_MAX_AGE_SECONDS - 1.0,
    )
    monkeypatch.setattr(doctor, "_alcove_following_enabled", lambda: True)
    monkeypatch.setattr(doctor, "alcove_follow_blocker", lambda **_kwargs: None)
    monkeypatch.setattr(doctor.time, "monotonic", lambda: now)

    finding = doctor._alcove_follow_state_probe()

    assert finding.code is doctor.DiagnosticCode.STALE
