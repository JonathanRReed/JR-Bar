from jrbar.core_state import CoreDomain, StateDelta
from jrbar.refresh_admission import admit_refresh


def delta(*domains: CoreDomain, urgent: bool = False) -> StateDelta:
    return StateDelta(
        1,
        1,
        2 if domains else 1,
        frozenset(domains),
        urgent,
    )


def test_noop_is_skipped_until_a_heartbeat_or_dynamic_display__and_2_more() -> None:
    # --- scenario: noop_is_skipped_until_a_heartbeat_or_dynamic_display
    quiet = admit_refresh(
        delta(),
        first_observation=False,
        heartbeat_due=False,
        dynamic_display=False,
        forced=False,
    )
    heartbeat = admit_refresh(
        delta(),
        first_observation=False,
        heartbeat_due=True,
        dynamic_display=False,
        forced=False,
    )
    dynamic = admit_refresh(
        delta(),
        first_observation=False,
        heartbeat_due=False,
        dynamic_display=True,
        forced=False,
    )

    assert quiet.admitted is False
    assert quiet.reason == "noop"
    assert heartbeat.reason == "heartbeat"
    assert heartbeat.admitted is True
    assert dynamic.reason == "dynamic-display"
    assert dynamic.admitted is True

    # --- scenario: urgent_change_and_explicit_force_are_never_dropped
    urgent = admit_refresh(
        delta(CoreDomain.ATTENTION, urgent=True),
        first_observation=False,
        heartbeat_due=False,
        dynamic_display=False,
        forced=False,
    )
    forced = admit_refresh(
        delta(),
        first_observation=False,
        heartbeat_due=False,
        dynamic_display=False,
        forced=True,
    )

    assert urgent.reason == "urgent"
    assert urgent.admitted is True
    assert forced.reason == "forced"
    assert forced.admitted is True

    # --- scenario: only_menu_relevant_domains_request_menu_work
    presentation = admit_refresh(
        delta(CoreDomain.PRESENTATION),
        first_observation=False,
        heartbeat_due=False,
        dynamic_display=False,
        forced=False,
    )
    agents = admit_refresh(
        delta(CoreDomain.AGENTS),
        first_observation=False,
        heartbeat_due=False,
        dynamic_display=False,
        forced=False,
    )

    assert presentation.update_menu is False
    assert agents.update_menu is True



# --- the daemon's refresh: admission sees the monitor ---------------------------

import json  # noqa: E402
import os  # noqa: E402
import subprocess  # noqa: E402
import sys  # noqa: E402
import tempfile  # noqa: E402
from pathlib import Path  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]

# The daemon's own composed controller (production admission on top), with
# fakes only at the process edges, fed synthetic Claude hooks through the
# product's hook path. It runs in a child so the composition does not leak
# into this process.
_DAEMON_REFRESH = r"""
import json, tempfile, threading, time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock

from jrbar import core_runtime, status_bar

tmp = Path(tempfile.mkdtemp())
status_bar.default_settings_path = lambda: tmp / "settings.json"
status_bar.default_latest_state_path = lambda: tmp / "latest.json"
status_bar.default_activity_ledger_path = lambda: tmp / "activity-ledger.json"
status_bar.discover_devices = lambda: []
status_bar.focus_sync.active_focus_mode_identifiers = lambda: []
status_bar.runtime_render_environment = lambda *, visible, display_asleep=False, process_info=None: SimpleNamespace(
    visible=visible, display_asleep=display_asleep, process_info=process_info)


class Timers:
    @classmethod
    def scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(cls, *args):
        return SimpleNamespace(invalidate=lambda: None, isValid=lambda: True)


class Server:
    def __init__(self, **kwargs):
        self.socket_path = tmp / "core.sock"
        self.kinds = []

    def start(self):
        return self.socket_path

    def stop(self, *, timeout_seconds=2.0):
        return None

    def client_count(self):
        return 1

    def publish_state(self, document):
        self.kinds.append("state")

    def publish_lights(self, document):
        self.kinds.append("lights")

    def publish_settings(self, document):
        self.kinds.append("settings")

    def publish_event(self, document):
        self.kinds.append("event")
        return document

    def publish_log(self, line, *, level="info"):
        return None


class Drainer:
    def __init__(self, submit, **kwargs):
        pass

    def drain_now(self):
        return 0

    def start(self):
        return None

    def stop(self, timeout_seconds=1.0):
        return None


class NoThread:
    def __init__(self, *args, **kwargs):
        pass

    def start(self):
        return None

    def is_alive(self):
        return False

    def join(self, timeout=None):
        return None


core_runtime.NSTimer = Timers
core_runtime.NSApp = SimpleNamespace(setActivationPolicy_=MagicMock(), terminate_=MagicMock())
core_runtime.CoreServer = Server
core_runtime.PendingHookDrainer = Drainer
core_runtime.default_state_dir = lambda *_: tmp / "state"

from jrbar.application_composition import compose_status_bar_application

compose_status_bar_application()
controller = core_runtime.build_headless_controller_class().alloc().init()
for name in (
    "load_operator_local_state", "trim_oversized_state_logs", "start_event_server",
    "start_cloud_ingest_server", "replay_debug_logs", "_install_dnd_environment_observers",
    "_refresh_dnd_environment", "refresh_installed_agent_inventory",
    "_install_accessibility_display_observer", "reconcile_lid_observation",
    "start_remote_peer_timer", "start_remote_peer_refresh", "sync_keep_awake",
    "sync_closed_lid_awake", "pollLiveness_",
):
    setattr(controller, name, MagicMock(name=name))
controller._deck_deliver_inline = True
real_thread = threading.Thread
core_runtime.threading.Thread = NoThread
try:
    controller.applicationDidFinishLaunching_(None)
finally:
    core_runtime.threading.Thread = real_thread

from jrbar.hook import process_hook_payload
from jrbar.providers import detect_log_path

log_path = detect_log_path("claude")


def hook(session, event):
    payload = json.dumps({"hook_event_name": event, "session_id": session, "cwd": "/tmp/synthetic", "transcript_path": f"/tmp/synthetic/{session}.jsonl", **({"prompt": "synthetic"} if event == "UserPromptSubmit" else {})})
    process_hook_payload(
        "claude", log_path, payload,
        refresh_hint_handler=lambda hint: controller.monitor.reconcile_refresh_hint(hint, log_path=log_path),
    )


builds = []
real_state = type(controller)._core_build_state
controller._core_build_state = lambda: builds.append(1) or real_state(controller)


def counts():
    snapshot = controller._performance().snapshot()
    return {name: getattr(snapshot.metric(name), "count", 0) for name in ("refresh", "refresh_skipped")}


def lifecycle(session):
    rows = controller._core_documents.get("state", {}).get("sessions", [])
    return next((row.get("mode") for row in rows if session in row.get("id", "")), None)


session = "0c0ffee0-5a5a-4b4b-8c8c-000000000001"
hook(session, "SessionStart")
hook(session, "UserPromptSubmit")
controller._production_force_refresh = True
controller.refresh_(None)
controller.refresh_(None)
out = {"working": lifecycle(session)}
before, built = counts(), len(builds)
controller.refresh_(None)
out["noop"] = {"skipped": counts()["refresh_skipped"] - before["refresh_skipped"],
               "refreshed": counts()["refresh"] - before["refresh"], "built": len(builds) - built}
controller._core_prev_asks = {"claude:session:x": (None, "ask")}
controller._core_ask_statuses = lambda: [SimpleNamespace(agent_id="claude:session:x")]
before, built = counts(), len(builds)
controller.refresh_(None)
out["ask_waiting"] = {"skipped": counts()["refresh_skipped"] - before["refresh_skipped"], "built": len(builds) - built}
del controller._core_ask_statuses
controller._core_prev_asks = {}
hook(session, "Stop")
before, built = counts(), len(builds)
controller.refresh_(None)
out["after_stop"] = {"refreshed": counts()["refresh"] - before["refresh"], "built": len(builds) - built,
                     "mode": lifecycle(session)}
print(json.dumps(out))
"""


def test_a_hook_that_only_moves_the_monitor_is_admitted_at_once__and_2_more() -> None:
    # --- scenario: a_hook_that_only_moves_the_monitor_is_admitted_at_once
    """A hook changed the monitor's operator state and nothing the old
    fingerprint read, so its refresh was a no-op and the app heard about it
    at the next 15 s heartbeat (p90 11 s late, live). The monitor's
    revision is fingerprinted now: the Stop is admitted and published."""
    with tempfile.TemporaryDirectory() as tempdir:
        env = os.environ.copy()
        env["HOME"] = tempdir
        env["XDG_STATE_HOME"] = str(Path(tempdir) / "state")
        env["XDG_CONFIG_HOME"] = str(Path(tempdir) / "config")
        env["PYTHONPATH"] = str(ROOT / "src")
        env["JRBAR_NO_SHELL_PATH"] = "1"
        env.pop("PYTEST_CURRENT_TEST", None)
        completed = subprocess.run(
            [sys.executable, "-c", _DAEMON_REFRESH],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    assert completed.returncode == 0, completed.stderr[-3000:]
    out = json.loads(completed.stdout.strip().splitlines()[-1])
    assert out["working"] not in (None, "completed")
    assert out["after_stop"]["refreshed"] == 1
    assert out["after_stop"]["mode"] != out["working"]

    # --- scenario: a_no_op_refresh_rebuilds_neither_document
    assert out["noop"] == {"skipped": 1, "refreshed": 0, "built": 0}

    # --- scenario: a_no_op_still_publishes_while_an_ask_waits
    """An ask's wait and hold move with the clock alone: the documents keep
    going out on every refresh, admitted or not."""
    assert out["ask_waiting"] == {"skipped": 1, "built": 1}
