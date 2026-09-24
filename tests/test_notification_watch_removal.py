from __future__ import annotations

import importlib.util
import json
from pathlib import Path

from jrbar.settings import AgentMonitorSettings, load_settings, save_settings


def test_legacy_foreign_notification_preferences_migrate_inertly(tmp_path: Path) -> None:
    path = tmp_path / "settings.json"
    path.write_text(
        json.dumps(
            {
                "notification_blinks_enabled": True,
                "notification_app_colors": {
                    "com.apple.MobileSMS": "#34C759",
                },
                "signal_styles": {
                    "notification": {
                        "color": "#34C759",
                        "pattern": "blink",
                        "speed_seconds": 0.3,
                        "intensity": 1.0,
                    },
                },
                "completion_notification_enabled": False,
            }
        ),
        encoding="utf-8",
    )

    settings = load_settings(path)

    assert not hasattr(settings, "notification_blinks_enabled")
    assert not hasattr(settings, "notification_app_colors")
    assert "notification" not in settings.signal_styles
    assert settings.completion_notification_enabled is False

    save_settings(settings, path)
    migrated = json.loads(path.read_text(encoding="utf-8"))
    assert migrated["completion_notification_enabled"] is False
    # signal_styles is a runtime-owned collection: the migrated-away
    # notification entry must actually leave the file, not merely stay
    # inert. Unknown top-level legacy keys still persist for downgrade
    # safety but can never activate on reload.
    assert "notification" not in migrated["signal_styles"]
    reloaded = load_settings(path)
    assert not hasattr(reloaded, "notification_blinks_enabled")
    assert not hasattr(reloaded, "notification_app_colors")
    assert "notification" not in reloaded.signal_styles


def test_trusted_controller_has_no_foreign_notification_watcher_lifecycle(
    monkeypatch,
    tmp_path: Path,
) -> None:
    from jrbar import status_bar

    monkeypatch.setattr(
        status_bar,
        "default_settings_path",
        lambda: tmp_path / "settings.json",
    )
    controller = status_bar.StatusBarController.alloc().init()

    assert not hasattr(status_bar.StatusBarController, "pollNotifications_")
    assert not hasattr(status_bar.StatusBarController, "notificationsChecked_")
    assert not hasattr(controller, "notification_watch_timer")
    assert not hasattr(controller, "notification_record_cursor")
    assert not hasattr(controller, "notification_watch_retry_at")
    assert not hasattr(controller, "notification_poll_in_flight")


def test_private_usernoted_watcher_is_not_packaged() -> None:
    assert importlib.util.find_spec("jrbar.notification_watch") is None


def test_the_daemon_launch_schedules_no_foreign_notification_poll() -> None:
    """The only launch is the daemon's (core_runtime _core_launch). Every
    repeating timer it arms is named here; a notification poll is not one."""
    import re

    from jrbar import core_runtime

    source = Path(core_runtime.__file__).read_text(encoding="utf-8")
    launch = source.split("def _core_launch(self)", 1)[1].split("\n        def ", 1)[0]
    selectors = re.findall(r'_schedule_timer\([^,]+, self, "([A-Za-z]+:)", True\)', launch)

    assert "pollNotifications" not in source
    assert selectors == [
        "refresh:",
        "pollLid:",
        "pollLiveness:",
        "coreHousekeepingTick:",
        "coreSupervisionTick:",
    ]
    # The peer timer is the only thing that fetches other Macs; it arms
    # itself rather than riding the refresh tick.
    assert "self.start_remote_peer_timer()" in launch


def test_sidepulse_owned_completion_notifications_remain_configurable(
    tmp_path: Path,
) -> None:
    path = tmp_path / "settings.json"
    configured = AgentMonitorSettings().with_completion_notification_enabled(False)

    save_settings(configured, path)

    reloaded = load_settings(path)
    assert reloaded.completion_notification_enabled is False
    assert hasattr(reloaded, "with_completion_notification_enabled")
