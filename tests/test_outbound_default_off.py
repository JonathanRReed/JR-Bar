"""Nothing leaves the Mac on a fresh settings document.

The standing rule is "a new outbound request is off until the person turns it
on, and a test proves it stays off". Each feature below is run from settings
the real loader produced for a first launch (no file), for a document that
holds none of the feature's keys, and for a document the app saved with every
default in it. Its real code path then runs with a tripwire in place of every
way out: `urlopen`, every opener, `socket.create_connection`, the Apple
network stack, the webhook sender and, for the features that shell out, the
subprocess call. Any attempt is recorded and raises, and the test asserts the
record is empty.

Provider usage quota (the collectors, the usage sync) has its own consent
tests and is not repeated here. Every wait is on a bounded event; nothing
sleeps and nothing reaches a real network, home folder or Keychain.
"""

from __future__ import annotations

import contextlib
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import pytest
from test_jrbar import isolate_controller

from jrbar.activity_ledger import ActivityEntry, ActivityKind
from jrbar.settings import (
    AgentMonitorSettings,
    load_settings,
    save_settings,
    settings_from_mapping,
)

ROOT = Path(__file__).resolve().parents[1]
NOW = 1_800_000_000.0

# --- the tripwire --------------------------------------------------------------------------------


class Net:
    """Every attempt to leave the Mac (or to run a command) lands here."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def trap(self, name: str):
        def refuse(*_args, **_kwargs):
            self.calls.append(name)
            raise AssertionError(f"{name} was called with default settings")

        return refuse


@contextlib.contextmanager
def tripwires(*, commands: tuple[str, ...] = ()):
    """Replace every outbound seam in the daemon with a recorder that raises.

    `commands` also traps the named `module.attribute` subprocess entry points
    (for the features that shell out to ssh, sftp or a user's own hook).
    """
    net = Net()
    seams = [
        "urllib.request.urlopen",
        "urllib.request.OpenerDirector.open",
        "socket.create_connection",
        "jrbar.status_feeds.build_opener",
        "jrbar.provider_updates.build_opener",
        "jrbar.cliproxy_hub.build_opener",
        "jrbar.provider_usage_collectors.build_opener",
        "jrbar.claude_quota.request_via_apple_stack",
        "jrbar.webhook_delivery.deliver_webhook",
        "jrbar.webhook_delivery.WebhookDeliveryService.submit",
        *commands,
    ]
    with contextlib.ExitStack() as stack:
        for seam in seams:
            stack.enter_context(mock.patch(seam, net.trap(seam)))
        yield net


def test_the_tripwire_itself_records_and_refuses() -> None:
    import urllib.request

    from jrbar import status_feeds

    with tripwires() as net:
        with pytest.raises(AssertionError):
            urllib.request.urlopen("https://example.invalid/")
        with pytest.raises(AssertionError):
            status_feeds.build_opener()
    assert net.calls == ["urllib.request.urlopen", "jrbar.status_feeds.build_opener"]


# --- fresh settings, three ways --------------------------------------------------------------------


@pytest.fixture(params=["no file", "an empty document", "unrelated keys only", "a saved default document"])
def settings(request: pytest.FixtureRequest, tmp_path: Path) -> AgentMonitorSettings:
    if request.param == "no file":
        return load_settings(tmp_path / "state" / "settings.json", track=False)
    if request.param == "an empty document":
        return settings_from_mapping({})
    if request.param == "unrelated keys only":
        return settings_from_mapping({"global_brightness_scale": 0.5})
    target = tmp_path / "saved" / "settings.json"
    target.parent.mkdir()
    save_settings(AgentMonitorSettings(), target)
    return load_settings(target, track=False)


def test_every_outbound_switch_is_off(settings: AgentMonitorSettings) -> None:
    assert settings.provider_status_feeds_enabled is False
    assert settings.provider_update_checks_enabled is False
    assert settings.cliproxy_hub["enabled"] is False
    assert settings.escalation_webhook_url == ""
    assert settings.webhook_events == ()
    assert settings.cloud_ingest_enabled is False
    assert settings.remote_peers.enabled is False
    assert settings.remote_peers.publish_enabled is False
    assert settings.usage_hooks == {"enabled": False, "rules": []}
    assert settings.usage_event_hook_path == ""
    assert settings.claude_plan_limits_enabled is False
    assert settings.claude_plan_limits_consent_version == 0


# --- provider status pages -------------------------------------------------------------------------


def test_status_pages_ask_no_vendor(settings: AgentMonitorSettings) -> None:
    from jrbar.provider_usage_runtime import status_feed_incident_lookup
    from jrbar.status_feeds import STATUS_FEED_THREAD_NAME, shared_status_feed_poller

    lookup = status_feed_incident_lookup(lambda: settings)
    with tripwires() as net:
        try:
            for provider in ("claude", "codex", "cursor"):
                assert lookup(provider, NOW) is None
        finally:
            shared_status_feed_poller().stop()
    feeds = [t for t in threading.enumerate() if t.name.startswith(STATUS_FEED_THREAD_NAME)]
    assert feeds == []
    assert net.calls == []


# --- provider update checks ------------------------------------------------------------------------


def test_update_checks_ask_no_registry(settings: AgentMonitorSettings) -> None:
    from jrbar.core_runtime import _provider_updates_of

    owner = SimpleNamespace(settings=settings)
    with tripwires() as net:
        updates = _provider_updates_of(owner)
        assert updates.check(forced=True) == {"enabled": False, "started": False}
        assert updates.check() == {"enabled": False, "started": False}
        updates.tick()
        assert updates.document() == {}
    assert net.calls == []


# --- the CLIProxyAPI hub ---------------------------------------------------------------------------


def test_the_hub_reads_no_key_and_asks_no_proxy(settings: AgentMonitorSettings) -> None:
    from jrbar.cliproxy_hub import HubSource, collect_hub

    with tripwires() as net:
        source = HubSource(
            settings_loader=lambda: settings,
            key_reader=net.trap("hub management key read"),
            identities=net.trap("hub local identities read"),
        )
        assert source(NOW) == ()
        assert source(NOW + 1000.0, force=True) == ()
        assert collect_hub(settings, now=NOW, key_reader=net.trap("hub management key read")) == ()
    assert net.calls == []


# --- usage hooks (local commands) --------------------------------------------------------------------


def test_usage_hooks_run_nothing(settings: AgentMonitorSettings) -> None:
    from jrbar.usage_event_hooks import (
        UsageHookLimiter,
        UsageHookResults,
        config_for_settings,
        dispatch_usage_hooks,
        sample_event,
    )

    config = config_for_settings(settings)
    assert config.enabled is False and config.rules == () and config.runnable() == ()
    with tripwires(commands=("jrbar.usage_event_hooks.subprocess.Popen", "subprocess.run")) as net:
        worker = dispatch_usage_hooks(
            config,
            (sample_event("quota_low", "claude"), sample_event("provider_unavailable", "codex")),
            limiter=UsageHookLimiter(),
            results=UsageHookResults(),
            log=lambda _line: None,
        )
    assert worker is None
    assert net.calls == []


# --- Claude's own usage endpoint (claude_plan_limits_enabled) ------------------------------------------


def test_claude_quota_fails_closed_without_a_token_and_asks_nothing() -> None:
    from jrbar import claude_quota

    sent: list[str] = []

    def requester(url, **_kwargs):
        sent.append(url)
        return 200, b"{}"

    for token in (None, "", "   "):
        with pytest.raises(claude_quota.ClaudeQuotaUnavailableError):
            claude_quota.fetch_windows(access_token=token, requester=requester)
    assert sent == []


# --- the controller's gates (webhooks, cloud ingest, remote peers, Claude plan limits) -----------------


def _entry(kind: ActivityKind, **overrides) -> ActivityEntry:
    base = dict(
        kind=kind,
        occurred_at_epoch=NOW,
        label="Codex work:01",
        provider="codex",
        subject_id="codex:session:work:01",
        detail=None,
    )
    base.update(overrides)
    return ActivityEntry(**base)


def _post_webhook_implementations(controller) -> list:
    """Every `post_webhook` the controller's class chain defines: the legacy
    urllib one and the production queue that replaces it."""
    found = []
    for cls in type(controller).__mro__:
        function = vars(cls).get("post_webhook")
        if function is not None:
            found.append(function)
    return found


class ControllerDefaultOffTests(unittest.TestCase):
    def setUp(self) -> None:
        isolate_controller(self)
        self.controller.leds_enabled = False
        # The controller starts from the loader's answer for a missing file.
        self.assertEqual(self.controller.settings.escalation_webhook_url, "")

    # -- webhooks --

    def test_webhooks_post_nothing_without_a_url(self) -> None:
        controller = self.controller
        payloads = [
            {"event": "jrbar.escalation", "stage": 3, "ask_count": 1},
            {"event": "jrbar.ask_opened", "provider": "codex", "label": "x"},
            {"event": "jrbar.failed", "provider": "codex", "label": "x"},
            {"event": "jrbar.quota_crossed", "provider": "claude", "label": "x"},
            {"event": "jrbar.completion", "provider": "codex", "label": "x"},
        ]
        implementations = _post_webhook_implementations(controller)
        self.assertGreaterEqual(len(implementations), 2, "the legacy and production senders")
        with tripwires() as net:
            for implementation in implementations:
                for payload in payloads:
                    implementation(controller, payload)
            controller.fire_escalation_webhook(3)
            controller.record_activity_entries(
                (
                    _entry(ActivityKind.ASKED),
                    _entry(ActivityKind.BLOCKED),
                    _entry(ActivityKind.COMPLETED),
                    _entry(ActivityKind.THRESHOLD_CROSSED, provider="claude", subject_id=None, detail="80%"),
                )
            )
        self.assertEqual(net.calls, [])

    def test_a_url_alone_sends_no_moment_event(self) -> None:
        # The URL is the consent for stage-3 escalation; every other moment
        # is its own opt-in in `webhook_events`, empty by default.
        controller = self.controller
        controller.settings = controller.settings.with_escalation_webhook_url("https://example.invalid/hook")
        self.assertEqual(controller.settings.webhook_events, ())
        with tripwires() as net:
            controller.record_activity_entries(
                (
                    _entry(ActivityKind.ASKED),
                    _entry(ActivityKind.BLOCKED),
                    _entry(ActivityKind.THRESHOLD_CROSSED, provider="claude", subject_id=None, detail="80%"),
                )
            )
        self.assertEqual(net.calls, [])

    # -- cloud ingest --

    def test_cloud_ingest_binds_no_port(self) -> None:
        controller = self.controller
        with (
            mock.patch.dict("os.environ", {"JRBAR_CLOUD_INGEST": "1"}),
            tripwires(
                commands=(
                    "jrbar.status_bar_legacy.start_cloud_ingest",
                    "jrbar.cloud_ingest.CloudIngestServer.start",
                )
            ) as net,
        ):
            controller.start_cloud_ingest_server()
        self.assertIsNone(getattr(controller, "cloud_ingest", None))
        self.assertEqual(net.calls, [])

    # -- remote peers --

    def test_remote_peers_discover_and_fetch_nothing_and_publish_nothing(self) -> None:
        controller = self.controller
        remote = controller.settings.remote_peers
        self.assertFalse(remote.enabled)
        self.assertFalse(remote.publish_enabled)
        publisher = mock.MagicMock(name="publisher")
        with (
            mock.patch.object(controller, "_ledger_publisher", return_value=publisher, create=True),
            mock.patch("jrbar.status_bar_legacy.threading.Thread", side_effect=AssertionError("a thread started")),
            tripwires(
                commands=(
                    "subprocess.run",
                    "subprocess.Popen",
                    "jrbar.remote_peers.discover_peers",
                    "jrbar.remote_peers.refresh_peers",
                )
            ) as net,
        ):
            controller.start_remote_peer_refresh()
            controller.refreshRemotePeers_(None)
            result = controller.refresh_remote_peers()
            controller.publish_local_ledger_now([])
        self.assertEqual((result.ledgers, result.health), ((), ()))
        publisher.request.assert_not_called()
        self.assertEqual(net.calls, [])

    # -- Claude plan limits --

    def test_claude_plan_limits_read_no_keychain_and_fetch_nothing(self) -> None:
        from jrbar.capacity_types import SourceKey

        controller = self.controller
        self.assertFalse(controller.settings.claude_plan_limits_enabled)
        published: list[dict] = []
        source_key = SourceKey("claude", "quota", "local", "remote_quota_windows")
        with (
            mock.patch.object(
                controller,
                "performSelectorOnMainThread_withObject_waitUntilDone_",
                side_effect=lambda _sel, payload, _wait: published.append(payload),
            ),
            tripwires(
                commands=(
                    "jrbar.status_bar_legacy.read_keychain_secret",
                    "jrbar.claude_quota.fetch_windows",
                )
            ) as net,
        ):
            self.assertFalse(controller._capacity_source_enabled("claude"))
            self.assertIsNone(controller.claude_access_token())
            controller._usage_refresh_source_worker(source_key, 1, None, {}, None)
        self.assertEqual(net.calls, [])
        self.assertEqual(len(published), 1)
        result = next(iter(published[0]["results"].values()))
        self.assertFalse(result["capacity_requested"])
        self.assertEqual(result["capacity_observations"], ())


# --- Sparkle: automatic checks are decided off before the updater starts -------------------------------


def test_sparkle_automatic_checks_are_written_off_before_the_updater_starts() -> None:
    """The Info.plist never carries `SUEnableAutomaticChecks` (the package
    contract pins that), so Sparkle would ask its own permission question and
    then poll. `SparkleUpdater.init` writes `false` into user defaults first,
    and only when the person has not chosen. A source contract, because the
    framework is not linked in every test build."""
    text = (ROOT / "app/Sources/JRBarApp/SparkleUpdater.swift").read_text(encoding="utf-8")
    decide = "defaults.object(forKey: Self.automaticChecksDefaultsKey) == nil"
    write_off = "defaults.set(false, forKey: Self.automaticChecksDefaultsKey)"
    start = "try controller.updater.start()"
    assert text.count(start) == 1 and text.count(write_off) == 1
    assert text.index(decide) < text.index(write_off) < text.index(start)
    assert "SPUStandardUpdaterController(startingUpdater: false" in text
    for forbidden in ("automaticallyChecksForUpdates = true", "setAutomaticallyChecksForUpdates(true"):
        assert forbidden not in text
    build = (ROOT / "app/scripts/build-app.sh").read_text(encoding="utf-8")
    assert "SUEnableAutomaticChecks" not in build
    assert "SUAutomaticallyUpdate" not in build
    assert "SUSendProfileInfo" not in build
